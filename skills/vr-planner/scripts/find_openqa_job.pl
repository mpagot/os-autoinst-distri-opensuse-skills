#!/usr/bin/perl
# find_openqa_job.pl — Find openQA jobs to clone for verification runs (VR).
# Run with --help for full usage information.

use strict;
use warnings;
use File::Basename;
use Getopt::Long;
use Cwd qw(abs_path);
use JSON::PP;
use Time::HiRes qw(gettimeofday tv_interval);

my $repo_dir;
my $host;
my $osd = 0;
my $o3 = 0;
my $casedir_override;
my $build_override;
my $verbose = 0;
my $json_output = 0;
my $timing = 0;
my $help = 0;
my @modules;    # programmatic-loader fallback: query by openQA module name

# Timing instrumentation: each entry is { stage, query, elapsed_s }
my @api_timings;

# Set to 1 once we discover the host needs MOJO_INSECURE=1 (self-signed cert).
# All subsequent calls re-use it so we only warn once.
my $https_insecure = 0;

GetOptions(
    'repo=s'    => \$repo_dir,
    'host=s'    => \$host,
    'osd'       => \$osd,
    'o3'        => \$o3,
    'casedir=s' => \$casedir_override,
    'build=s'   => \$build_override,
    'verbose'   => \$verbose,
    'json'      => \$json_output,
    'timing'    => \$timing,
    'modules=s' => \@modules,
    'help|h'    => \$help,
) or do { print_usage(); exit 1 };

print_usage() && exit 0 if $help;

# --- Resolve host ---
my $host_count = (defined $host ? 1 : 0) + $osd + $o3;
if ($host_count == 0) {
    die "Error: --host, --osd, or --o3 is required.\n"
        . "  --osd  →  http://openqa.suse.de\n"
        . "  --o3   →  http://openqa.opensuse.org\n";
}
if ($host_count > 1) {
    die "Error: specify exactly one of --host, --osd, --o3.\n";
}
$host = 'http://openqa.suse.de' if $osd;
$host = 'http://openqa.opensuse.org' if $o3;
$host =~ s{/$}{};    # strip trailing slash

# --- Resolve repo ---
$repo_dir //= '.';
$repo_dir = abs_path($repo_dir);
die "Not a valid OSADO repo: $repo_dir (missing tests/)\n"
    unless -d "$repo_dir/tests";

# --- Validate inputs ---
my @input_files = @ARGV;
die "No input files. Pass test module paths (tests/*.pm) or schedule paths (schedule/*.yml).\n"
    unless @input_files || @modules;

# Normalize paths (strip repo prefix, leading ./)
@input_files = map {
    my $f = $_;
    $f =~ s{^\Q$repo_dir\E/}{};
    $f =~ s{^\.\/}{};
    $f;
} @input_files;

log_verbose("Host: $host");
log_verbose("Repo: $repo_dir");
log_verbose("Input files (" . scalar(@input_files) . "): " . join(", ", @input_files));

# --- Verify openqa-cli is available ---
my $openqa_cli = `which openqa-cli 2>/dev/null`;
chomp $openqa_cli;
die "openqa-cli not found — install the openQA-client package.\n"
    unless $openqa_cli;
log_verbose("openqa-cli: $openqa_cli");

# --- Detect git info for CASEDIR/BUILD ---
my $casedir = $casedir_override;
my $build = $build_override;
my $branch;
my $fork_url;

if (!$casedir || !$build) {
    $branch = get_git_branch($repo_dir);
    $fork_url = get_git_fork_url($repo_dir);
    log_verbose("Git branch: " . ($branch // '(unknown)'));
    log_verbose("Git fork URL: " . ($fork_url // '(unknown)'));

    if (!$casedir && $fork_url && $branch) {
        $casedir = "${fork_url}.git#${branch}";
    }

    if (!$build && $fork_url) {
        # Extract username from URL: https://github.com/USER/REPO → USER
        if ($fork_url =~ m{github\.com/([^/]+)/}) {
            $build = "${1}_VR";
        }
    }
    $build //= 'VR';
}

log_verbose("CASEDIR: " . ($casedir // '<not detected — use --casedir>'));
log_verbose("BUILD: $build");


################################################################
# Programmatic loader fallback (--modules): query by module name
################################################################
# Some tests (publiccloud, parts of kernel/LTP) are loaded at runtime via
# lib/main_*.pm and have no static YAML schedule, so the schedule-based
# pipeline below cannot resolve them. As a fallback, query openQA directly by
# module name to locate a recent passing job to clone. job_modules.name is not
# indexed: the query is fast for commonly-run modules but scans the whole table
# (minutes) for rare or unknown names, so it is gated behind an explicit
# --modules request. All traffic goes through run_openqa_api to reuse
# the https/insecure/http fallback and shell-safe execution.
if (@modules) {
    run_modules_query(\@modules);
    exit 0;
}


################################################################
# Validate inputs — only schedule/*.yml accepted
################################################################

my @schedule_entries;
my @hints;    # caller may pass hints via --hint, or we generate them for skipped files
my @skipped_test_files;

for my $f (@input_files) {
    if ($f =~ m{^schedule/.*\.ya?ml$}) {
        push @schedule_entries, {
            schedule     => $f,
            source_files => [$f],
            type         => 'direct',
        };
        log_verbose("Schedule input: $f");
    } elsif ($f =~ m{^tests/.*\.pm$}) {
        # tests/*.pm are no longer accepted directly — the caller must resolve
        # them to schedule files first via find_test_schedule.pl
        push @skipped_test_files, $f;
    } else {
        warn "Warning: skipping '$f' — expected schedule/*.yml\n";
    }
}

if (@skipped_test_files) {
    my $list = join(', ', @skipped_test_files);
    warn "Warning: skipping " . scalar(@skipped_test_files) . " test file(s): $list\n"
        . "  Resolve test files to schedules first with find_test_schedule.pl,\n"
        . "  then pass the schedule paths to this script.\n";
    for my $f (@skipped_test_files) {
        push @hints, {
            test_file => $f,
            type      => 'skipped_test_file',
            message   => "$f — test files must be resolved to schedule files first "
                . "(use find_test_schedule.pl --json, then pass schedule paths here).",
        };
    }
}

if (!@schedule_entries) {
    if (@hints) {
        print_hints_only(\@hints);
        exit 0;
    }
    die "No schedule files provided. Pass schedule/*.yml paths.\n"
        . "  To resolve test files first: perl find_test_schedule.pl --repo REPO --json tests/foo.pm\n";
}

log_verbose("Unique schedules to query: " . scalar(@schedule_entries));


################################################################
# STAGE 1: YAML schedule → job IDs via job_settings/jobs API
################################################################

log_verbose("\n=== Stage 1: YAML schedule → job IDs (API) ===");

for my $se (@schedule_entries) {
    my $path = $se->{schedule};
    my $raw = run_openqa_api(["job_settings/jobs", "key=YAML_SCHEDULE", "value=$path"], 'stage1_schedule_to_jobs');

    if (!$raw) {
        $se->{job_ids} = [];
        $se->{error} = "API call failed";
        warn "Warning: API query failed for schedule '$path'\n";
        next;
    }

    my $data = eval { JSON::PP->new->decode($raw) };
    if ($@ || !$data || !$data->{jobs}) {
        $se->{job_ids} = [];
        $se->{error} = "Failed to parse API response";
        warn "Warning: could not parse API response for '$path'\n";
        next;
    }

    $se->{job_ids} = $data->{jobs};
    my $count = scalar @{$se->{job_ids}};
    log_verbose("$path → $count job IDs");

    if ($count == 0) {
        $se->{error} = "No jobs found with this YAML_SCHEDULE on $host";
        warn "Warning: no jobs found for YAML_SCHEDULE=$path on $host\n";
    }
}


################################################################
# STAGE 2: Sample job IDs → extract TEST names + metadata
################################################################

log_verbose("\n=== Stage 2: Job ID sampling → TEST name discovery ===");

# For each schedule, sample up to 5 recent job IDs to find unique TEST names
my $MAX_SAMPLES = 5;

for my $se (@schedule_entries) {
    next unless @{$se->{job_ids} // []};

    my @sample_ids = @{$se->{job_ids}}[0 .. min_idx($MAX_SAMPLES - 1, $#{$se->{job_ids}})];
    my %tests_seen;    # TEST → { group_id, flavor, version, distri, arch, sample_id }

    for my $id (@sample_ids) {
        my $raw = run_openqa_api(["jobs/$id"], 'stage2_job_metadata');
        next unless $raw;

        my $data = eval { JSON::PP->new->decode($raw) };
        next if $@ || !$data;

        # The jobs/<id> endpoint wraps in {"job": {...}}
        my $job = $data->{job} // $data;
        my $settings = $job->{settings} // {};
        my $test_name = $settings->{TEST} // $job->{test} // next;
        my $group_id = $job->{group_id};

        if (!exists $tests_seen{$test_name}) {
            $tests_seen{$test_name} = {
                test      => $test_name,
                group_id  => $group_id,
                flavor    => $settings->{FLAVOR} // '',
                version   => $settings->{VERSION} // '',
                distri    => $settings->{DISTRI} // '',
                arch      => $settings->{ARCH} // '',
                machine   => $settings->{MACHINE} // '',
                sample_id => $id,
            };
            log_verbose("  #$id → TEST=$test_name group_id=" . ($group_id // 'null')
                . " FLAVOR=$settings->{FLAVOR} VERSION=$settings->{VERSION}");
        }
    }

    $se->{discovered_tests} = [values %tests_seen];
    log_verbose("Schedule '$se->{schedule}': " . scalar(keys %tests_seen) . " unique TEST name(s)");
}


################################################################
# STAGE 3: TEST + group_id → find recent passing jobs
################################################################

log_verbose("\n=== Stage 3: Find recent passing jobs ===");

# ------------------------------------------------------------------
# Pre-filter and deduplicate TEST+group_id pairs across ALL schedule
# entries before making any API calls.
#
# Why dedup is needed:
#   Multiple schedule entries can discover the same TEST name and
#   group_id via stage-2 sampling (e.g. schedule/ha/bv/node01.yaml
#   and schedule/ha/bv/node02.yaml both yield TEST=ha_2nodes_node01,
#   groupid=607).  Without dedup, stage 3 issues duplicate API calls
#   — observed as 3× for sles_migration_160 in PR #24909.
#
# Why filter TEST names containing '@':
#   When openqa-clone-job is used with a CASEDIR pointing at a GitHub
#   fork (e.g. CASEDIR=https://github.com/user/repo.git#branch), the
#   resulting job's TEST name is mangled to encode that fork reference:
#     sles_migration_15sp7...@waynechen55/os-autoinst-distri-opensuse#wayne/...
#   These "VR-clone" TEST names are unique one-offs that belong to the
#   developer who created the clone.  No production scheduler job will
#   ever have that TEST name, so querying stage 3 for it always returns
#   zero results — but the query itself still costs 10–75 seconds of
#   wall time against the openQA API (the server scans every matching
#   row before returning empty).  Filtering out TEST names that contain
#   '@' eliminates these dead-end queries.
#   Observed in: alvarocarvajald PR #24909 (74.4 s wasted on a single
#   @waynechen55/... query), chcao PR #24793 (@tinawang123/, @fsimorda/).
#
# Why filter TEST names containing ':investigate:':
#   openQA's auto-review mechanism appends ":investigate:" (and
#   sometimes ":investigate:retry") to the TEST name of jobs that
#   failed with a known transient issue and were automatically
#   retried.  The original production TEST name is "foo_bar";
#   the retry is "foo_bar:investigate:retry".  The ":investigate:"
#   variants are never scheduled directly — they only appear as
#   automatic retries — so searching stage 3 for them
#   (state=done result=passed) always returns zero results.  These
#   queries are frequent because stage-2 sampling often hits recent
#   investigate jobs, and each fruitless query costs 2–5 seconds.
#   Observed in: both alvarocarvajald and chcao analysis logs, e.g.
#   "sles_migration_15sp7_textmode:investigate:retry groupid=637
#    → no passing jobs".
# ------------------------------------------------------------------

my @recommendations;
my @skipped_tests;    # TEST names filtered out (surfaced in hints)

# Collect unique TEST+group_id pairs across all schedule entries,
# keeping the first-seen schedule + metadata for attribution.
my %unique_tests;     # key = "$test||$gid" → { td => ..., schedule => ... }

for my $se (@schedule_entries) {
    for my $td (@{$se->{discovered_tests} // []}) {
        my $test = $td->{test};
        my $gid  = $td->{group_id};
        my $key  = $test . '||' . ($gid // 'null');
        next if exists $unique_tests{$key};
        $unique_tests{$key} = { td => $td, schedule => $se->{schedule} };
    }
}

my $dedup_before = 0;
for my $se (@schedule_entries) {
    $dedup_before += scalar @{$se->{discovered_tests} // []};
}
log_verbose("Stage 3 dedup: $dedup_before total TEST+group pairs → "
    . scalar(keys %unique_tests) . " unique");

# Apply filters and query the API for each unique pair.
for my $key (sort keys %unique_tests) {
    my $td       = $unique_tests{$key}{td};
    my $schedule = $unique_tests{$key}{schedule};
    my $test     = $td->{test};
    my $gid      = $td->{group_id};

    # --- Filter: VR-clone TEST names (contain '@') ---
    if ($test =~ /\@/) {
        log_verbose("  SKIP (VR-clone \@ in TEST): $test");
        push @skipped_tests, {
            test     => $test,
            reason   => 'VR-clone TEST name (contains @)',
            schedule => $schedule,
        };
        next;
    }

    # --- Filter: :investigate: retry TEST names ---
    if ($test =~ /:investigate:/) {
        log_verbose("  SKIP (:investigate: in TEST): $test");
        push @skipped_tests, {
            test     => $test,
            reason   => 'Auto-review :investigate: variant',
            schedule => $schedule,
        };
        next;
    }

    # Build query: always filter by TEST, state, result, latest
    # Add groupid if available (excludes VR clones with _GROUP=0)
    my @query_args = ('jobs', "test=$test", 'state=done', 'result=passed', 'latest=1', 'limit=5');
    push @query_args, "groupid=$gid" if defined $gid;

    my $raw = run_openqa_api(\@query_args, 'stage3_passing_jobs');
    next unless $raw;

    my $data = eval { JSON::PP->new->decode($raw) };
    next if $@ || !$data;

    my @jobs_list = @{$data->{jobs} // []};
    log_verbose("TEST=$test groupid=" . ($gid // 'null') . " → " . scalar(@jobs_list) . " passing job(s)");

    if (!@jobs_list) {
        warn "Warning: no passing jobs found for TEST=$test"
            . (defined $gid ? " groupid=$gid" : "") . " on $host\n";
        push @recommendations, {
            test     => $test,
            group_id => $gid,
            schedule => $schedule,
            flavor   => $td->{flavor},
            version  => $td->{version},
            distri   => $td->{distri},
            arch     => $td->{arch},
            jobs     => [],
            error    => "No passing jobs found",
        };
        next;
    }

    # Extract job details — pick the most recent ones
    my @passing;
    for my $j (@jobs_list) {
        my $s = $j->{settings} // {};
        push @passing, {
            id      => $j->{id},
            flavor  => $s->{FLAVOR} // $td->{flavor},
            version => $s->{VERSION} // $td->{version},
            distri  => $s->{DISTRI} // $td->{distri},
            arch    => $s->{ARCH} // $td->{arch},
            result  => $j->{result} // 'passed',
            state   => $j->{state} // 'done',
            t_finished => $j->{t_finished} // '',
        };
    }

    push @recommendations, {
        test     => $test,
        group_id => $gid,
        schedule => $schedule,
        flavor   => $td->{flavor},
        version  => $td->{version},
        distri   => $td->{distri},
        arch     => $td->{arch},
        jobs     => \@passing,
    };
}

if (@skipped_tests) {
    log_verbose("Stage 3: skipped " . scalar(@skipped_tests) . " TEST name(s):");
    for my $s (@skipped_tests) {
        log_verbose("  $s->{test} — $s->{reason}");
    }
}


################################################################
# STAGE 4: Output
################################################################

if ($json_output) {
    print_json_output(\@schedule_entries, \@recommendations, \@hints, \@skipped_tests);
} else {
    print_human_output(\@schedule_entries, \@recommendations, \@hints, \@skipped_tests);
}

# Print timing summary to stderr when --timing is enabled
if ($timing && @api_timings) {
    print_timing_summary();
}

exit 0;


################################################################
# API helper
################################################################

sub run_openqa_api {
    my ($args_ref, $stage) = @_;

    # Always try first without any insecure override — trust the user's
    # system certificate store.
    my $raw = _do_openqa_api_call($host, $args_ref, $stage, 0);
    return $raw if defined $raw;

    # Nothing more to try for plain http hosts.
    return undef unless $host =~ m{^https://};

    # --- Fallback 1: retry https with MOJO_INSECURE=1 (self-signed cert) ---
    if (!$https_insecure) {
        warn "Warning: API call failed for '$host';"
            . " retrying with MOJO_INSECURE=1 (untrusted certificate?)\n";
        $raw = _do_openqa_api_call($host, $args_ref, $stage, 1);
        if (defined $raw) {
            $https_insecure = 1;    # remember for all subsequent calls
            return $raw;
        }
    }

    # --- Fallback 2: retry with http:// (host may not serve https at all) ---
    my $http_host = $host;
    $http_host =~ s{^https://}{http://};
    warn "Warning: https failed for '$host'; retrying with '$http_host'\n"
        . "  Internal openQA instances do not always serve HTTPS.\n";
    $raw = _do_openqa_api_call($http_host, $args_ref, $stage, 0);
    if (defined $raw) {
        $host           = $http_host;    # permanently switch for subsequent calls
        $https_insecure = 0;
    }
    return $raw;
}

# Low-level helper: run one openqa-cli call against a given host.
# $insecure=1 sets MOJO_INSECURE=1 in the environment.
# Returns the raw response string, or undef on failure.
sub _do_openqa_api_call {
    my ($try_host, $args_ref, $stage, $insecure) = @_;

    # Safely set MOJO_INSECURE using dynamic/local scope in Perl %ENV
    local $ENV{MOJO_INSECURE} = 1 if $insecure;
    my @cmd = ('openqa-cli', 'api', '--host', $try_host, @$args_ref);
    # Human-readable command for the verbose log only (quoting is cosmetic, never executed)
    my $cmd_str = join(' ', map { $_ =~ /[\s']/ ? "'$_'" : $_ } @cmd);
    log_verbose("API: $cmd_str");

    my $t0 = [gettimeofday()] if $timing;
    # Safe list form of open to execute without shell interpolation
    my $pid = open(my $fh, "-|", @cmd);
    unless ($pid) {
        log_verbose("Failed to execute openqa-cli: $!");
        return undef;
    }

    my $raw = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    my $elapsed = $timing ? tv_interval($t0) : 0;

    if ($timing) {
        my $query_str = join(' ', @$args_ref);
        my $entry = {
            stage     => $stage // 'unknown',
            query     => $query_str,
            elapsed_s => sprintf("%.3f", $elapsed),
        };
        push @api_timings, $entry;
        printf STDERR "[TIMING] %.3fs  %s  %s\n", $elapsed, ($stage // ''), $query_str;
    }

    if ($rc != 0) {
        log_verbose("openqa-cli failed with exit code $rc");
        return undef;
    }

    chomp $raw if defined $raw;
    return $raw if defined $raw && length $raw;
    return undef;
}


################################################################
# Programmatic loader fallback: openQA module-name query
################################################################

# openQA stores each job module under its bare basename (e.g. a test loaded
# from tests/publiccloud/download_repos.pm is module "download_repos" — the
# category is a separate column, NOT part of the module= filter). Normalize any
# accepted form (repo-relative path, tests/*.pm, or bare name) down to that
# basename. Exception: loadtest(..., name => 'x') stores 'x' instead, so pass
# the bare name for tests loaded that way.
sub normalize_module_name {
    my ($m) = @_;
    $m =~ s{\.pm$}{};    # strip extension
    $m =~ s{.*/}{};      # reduce to basename — openQA module names carry no category path
    return $m;
}

sub run_modules_query {
    my ($modules_ref) = @_;
    my $limit = 3;

    my @results;
    for my $mod (@$modules_ref) {
        my $bare = normalize_module_name($mod);
        log_verbose("Module query: '$mod' → openQA module name '$bare'");

        # openQA matches module names exactly (and splits on commas), and
        # job_modules.name has no index: a name that matches nothing costs a
        # full table scan (minutes on o3). Reject anything that cannot be a name.
        if ($bare !~ /^\w+$/) {
            warn "Warning: skipping '$mod' — not a valid openQA module name\n";
            push @results, { module => $bare, jobs => [], error => "Invalid module name" };
            next;
        }

        # result=passed (job-level) mirrors stage 3 and yields a clean clone
        # baseline; modules=<name> restricts to jobs that ran this module.
        # not_groupid=0 (server-side "group_id IS NOT NULL") drops VR clones
        # posted with _GROUP=0, like the groupid filter does in stage 3.
        my @query_args = ('jobs', "modules=$bare", 'result=passed', 'not_groupid=0',
            'latest=1', "limit=$limit");
        my $raw = run_openqa_api(\@query_args, 'modules_query');

        my $rec = { module => $bare, jobs => [] };
        if (!$raw) {
            $rec->{error} = "API call failed";
            warn "Warning: modules query failed for '$bare' on $host\n";
            push @results, $rec;
            next;
        }

        my $data = eval { JSON::PP->new->decode($raw) };
        if ($@ || !$data) {
            $rec->{error} = "Failed to parse API response";
            warn "Warning: could not parse modules response for '$bare'\n";
            push @results, $rec;
            next;
        }

        my @jobs_list = @{$data->{jobs} // []};
        log_verbose("module=$bare → " . scalar(@jobs_list) . " passing job(s) in a job group");
        if (!@jobs_list) {
            $rec->{error} = "No passing jobs found in a job group";
            warn "Warning: no passing jobs in a job group found for module '$bare' on $host\n"
                . "  The module name must match openQA's bare basename (e.g. 'download_repos').\n";
            push @results, $rec;
            next;
        }

        for my $j (@jobs_list) {
            my $s = $j->{settings} // {};
            push @{$rec->{jobs}}, {
                id         => $j->{id},
                flavor     => $s->{FLAVOR} // '',
                version    => $s->{VERSION} // '',
                distri     => $s->{DISTRI} // '',
                arch       => $s->{ARCH} // '',
                result     => $j->{result} // 'passed',
                state      => $j->{state} // 'done',
                t_finished => $j->{t_finished} // '',
            };
        }
        push @results, $rec;
    }

    if ($json_output) {
        print_modules_json(\@results);
    } else {
        print_modules_human(\@results);
    }

    if ($timing && @api_timings) {
        print_timing_summary();
    }
}

sub print_modules_json {
    my ($results) = @_;

    my @recs_out;
    for my $r (@$results) {
        my %rec = (module => $r->{module});
        if ($r->{error}) {
            $rec{error} = $r->{error};
            $rec{passing_jobs} = [];
        } else {
            $rec{passing_jobs} = $r->{jobs};
            $rec{clone_command} = build_clone_cmd($r->{jobs}[0]{id}) if @{$r->{jobs}};
        }
        push @recs_out, \%rec;
    }

    my %out = (
        host            => $host,
        casedir         => $casedir,
        build           => $build,
        query           => 'modules',
        recommendations => \@recs_out,
    );

    if ($timing && @api_timings) {
        my $total = 0;
        $total += $_->{elapsed_s} for @api_timings;
        $out{timing} = {
            total_api_calls => scalar @api_timings,
            total_elapsed_s => sprintf("%.3f", $total),
            calls           => \@api_timings,
            by_stage        => build_timing_by_stage(),
        };
    }

    print JSON::PP->new->pretty->canonical->encode(\%out);
}

sub print_modules_human {
    my ($results) = @_;

    print "=" x 60 . "\n";
    print "find_openqa_job.pl — openQA Job Discovery (module query)\n";
    print "=" x 60 . "\n\n";

    print "Host:    $host\n";
    print "CASEDIR: " . ($casedir // '<not detected — use --casedir>') . "\n";
    print "BUILD:   $build\n\n";

    print "--- Clone Candidates ---\n\n";
    for my $r (@$results) {
        print "  module=$r->{module}\n";
        if ($r->{error}) {
            print "    ⚠ $r->{error}\n\n";
            next;
        }
        for my $j (@{$r->{jobs}}) {
            printf "    #%-10d %-30s %-10s %s  %s\n",
                $j->{id}, $j->{flavor}, $j->{version}, $j->{result}, $j->{t_finished};
        }
        print "\n";
    }

    print "--- Clone Commands (copy-paste ready) ---\n\n";
    my $printed = 0;
    for my $r (@$results) {
        next if $r->{error};
        next unless @{$r->{jobs}};
        my $j = $r->{jobs}[0];
        print "  # module $r->{module} ($j->{version}, $j->{flavor})\n";
        print "  " . build_clone_cmd($j->{id}) . "\n\n";
        $printed++;
    }
    print "  (no clonable jobs found)\n\n" unless $printed;
}


################################################################
# Timing helpers
################################################################

sub build_timing_by_stage {
    my %by_stage;
    for my $t (@api_timings) {
        my $s = $t->{stage};
        $by_stage{$s} //= { calls => 0, total_s => 0 };
        $by_stage{$s}{calls}++;
        $by_stage{$s}{total_s} += $t->{elapsed_s};
    }
    # Round totals
    for my $s (keys %by_stage) {
        $by_stage{$s}{total_s} = sprintf("%.3f", $by_stage{$s}{total_s});
    }
    return \%by_stage;
}

sub print_timing_summary {
    my $total = 0;
    $total += $_->{elapsed_s} for @api_timings;

    my $by_stage = build_timing_by_stage();

    print STDERR "\n" . "=" x 60 . "\n";
    print STDERR "TIMING SUMMARY\n";
    print STDERR "=" x 60 . "\n\n";

    printf STDERR "  %-30s  %5s  %8s\n", "Stage", "Calls", "Total(s)";
    printf STDERR "  %-30s  %5s  %8s\n", "-" x 30, "-" x 5, "-" x 8;

    for my $stage (sort keys %$by_stage) {
        my $s = $by_stage->{$stage};
        printf STDERR "  %-30s  %5d  %8s\n", $stage, $s->{calls}, $s->{total_s};
    }

    printf STDERR "\n  %-30s  %5d  %8.3f\n", "TOTAL", scalar(@api_timings), $total;
    print STDERR "\n";
}


################################################################
# Output: JSON (via JSON::PP — the good pattern)
################################################################

sub print_json_output {
    my ($schedules, $recs, $hints, $skipped) = @_;

    my %out = (
        host    => $host,
        inputs  => \@input_files,
        casedir => $casedir,
        build   => $build,
    );

    # Schedules
    my @sched_out;
    for my $se (@$schedules) {
        push @sched_out, {
            schedule_file   => $se->{schedule},
            source_files    => $se->{source_files},
            type            => $se->{type},
            total_job_ids   => scalar(@{$se->{job_ids} // []}),
            unique_tests    => [map { $_->{test} } @{$se->{discovered_tests} // []}],
            ($se->{error} ? (error => $se->{error}) : ()),
        };
    }
    $out{schedules} = \@sched_out;

    # Recommendations
    my @recs_out;
    for my $r (@$recs) {
        my %rec = (
            test     => $r->{test},
            group_id => $r->{group_id},
            schedule => $r->{schedule},
            flavor   => $r->{flavor},
            version  => $r->{version},
            distri   => $r->{distri},
            arch     => $r->{arch},
        );

        if ($r->{error}) {
            $rec{error} = $r->{error};
            $rec{passing_jobs} = [];
        } else {
            $rec{passing_jobs} = $r->{jobs};
            if (@{$r->{jobs}}) {
                my $j = $r->{jobs}[0];
                $rec{clone_command} = build_clone_cmd($j->{id});
            }
        }
        push @recs_out, \%rec;
    }
    $out{recommendations} = \@recs_out;

    # isos POST info (deduplicated by product tuple)
    my %products;
    for my $r (@$recs) {
        next if $r->{error};
        next unless @{$r->{jobs} // []};
        my $j = $r->{jobs}[0];
        my $key = join('|', $j->{distri}, $j->{version}, $j->{flavor}, $j->{arch});
        next if $products{$key};
        $products{$key} = {
            distri  => $j->{distri},
            version => $j->{version},
            flavor  => $j->{flavor},
            arch    => $j->{arch},
            command => build_isos_cmd($j),
            caveat  => "Triggers ALL scenarios for this product, not just the discovered TEST(s)",
        };
    }
    $out{isos_post} = [values %products] if %products;

    # Hints
    if (@$hints) {
        $out{hints} = [map {
            {
                test_file   => $_->{test_file},
                type        => $_->{type},
                message     => $_->{message},
                ($_->{loader_file} ? (loader_file => $_->{loader_file}) : ()),
            }
        } @$hints];
    }

    # Skipped TEST names (filtered out before stage-3 API queries)
    if (@$skipped) {
        $out{skipped_tests} = [map {
            {
                test     => $_->{test},
                reason   => $_->{reason},
                schedule => $_->{schedule},
            }
        } @$skipped];
    }

    # Timing data (only when --timing is enabled)
    if ($timing && @api_timings) {
        my $total = 0;
        $total += $_->{elapsed_s} for @api_timings;
        $out{timing} = {
            total_api_calls => scalar @api_timings,
            total_elapsed_s => sprintf("%.3f", $total),
            calls           => \@api_timings,
            by_stage        => build_timing_by_stage(),
        };
    }

    print JSON::PP->new->pretty->canonical->encode(\%out);
}


################################################################
# Output: Human-readable
################################################################

sub print_human_output {
    my ($schedules, $recs, $hints, $skipped) = @_;

    print "=" x 60 . "\n";
    print "find_openqa_job.pl — openQA Job Discovery\n";
    print "=" x 60 . "\n\n";

    print "Host:    $host\n";
    print "CASEDIR: " . ($casedir // '<not detected — use --casedir>') . "\n";
    print "BUILD:   $build\n\n";

    # Stage 1+2 summary
    print "--- Schedule Resolution ---\n\n";
    for my $se (@$schedules) {
        my $src = join(', ', @{$se->{source_files}});
        my $count = scalar @{$se->{job_ids} // []};
        printf "  %-60s → %d job(s)\n", $se->{schedule}, $count;
        if ($se->{error}) {
            print "    ⚠ $se->{error}\n";
        }
        if (@{$se->{discovered_tests} // []}) {
            my @names = map { $_->{test} } @{$se->{discovered_tests}};
            print "    TEST names: " . join(', ', @names) . "\n";
        }
    }
    print "\n";

    # Skipped TEST names (filtered before stage-3 API queries)
    if (@$skipped) {
        print "--- Skipped TEST Names (" . scalar(@$skipped) . ") ---\n\n";
        for my $s (@$skipped) {
            print "  $s->{test}\n";
            print "    reason: $s->{reason}\n";
            print "    from:   $s->{schedule}\n";
        }
        print "\n";
    }

    # Stage 3 results + clone commands
    if (@$recs) {
        print "--- Clone Candidates ---\n\n";

        for my $r (@$recs) {
            my $gid_str = defined $r->{group_id} ? $r->{group_id} : 'null';
            print "  TEST=$r->{test}  groupid=$gid_str\n";

            if ($r->{error}) {
                print "    ⚠ $r->{error}\n\n";
                next;
            }

            for my $j (@{$r->{jobs}}) {
                printf "    #%-10d %-30s %-10s %s  %s\n",
                    $j->{id}, $j->{flavor}, $j->{version},
                    $j->{result}, $j->{t_finished};
            }
            print "\n";
        }

        print "--- Clone Commands (copy-paste ready) ---\n\n";

        my $printed = 0;
        for my $r (@$recs) {
            next if $r->{error};
            next unless @{$r->{jobs}};

            my $j = $r->{jobs}[0];
            my $gid_str = defined $r->{group_id} ? $r->{group_id} : '?';
            print "  # $r->{test} ($j->{version}, $j->{flavor})\n";
            print "  " . build_clone_cmd($j->{id}) . "\n\n";
            $printed++;
        }
        if (!$printed) {
            print "  (no clonable jobs found)\n\n";
        }

        # isos POST section
        my %products;
        for my $r (@$recs) {
            next if $r->{error};
            next unless @{$r->{jobs} // []};
            my $j = $r->{jobs}[0];
            my $key = join('|', $j->{distri}, $j->{version}, $j->{flavor}, $j->{arch});
            next if $products{$key};
            $products{$key} = $j;
        }

        if (%products) {
            print "--- isos POST (triggers ALL scenarios for matched products) ---\n\n";
            for my $j (values %products) {
                print "  " . build_isos_cmd($j) . "\n";
                print "  # WARNING: Creates jobs for ALL scenarios in this product, not just the above TEST(s).\n\n";
            }
        }
    }

    # Hints for programmatic / unresolved tests
    if (@$hints) {
        print "--- Hints ---\n\n";
        for my $h (@$hints) {
            print "  $h->{message}\n";
        }
        print "\n";
    }
}

sub print_hints_only {
    my ($hints) = @_;

    if ($json_output) {
        my %out = (
            host   => $host,
            inputs => \@input_files,
            hints  => [map {
                {
                    test_file   => $_->{test_file},
                    type        => $_->{type},
                    message     => $_->{message},
                    ($_->{loader_file} ? (loader_file => $_->{loader_file}) : ()),
                }
            } @$hints],
        );
        print JSON::PP->new->pretty->canonical->encode(\%out);
    } else {
        print "No YAML schedules found for the given test files.\n\n";
        print "--- Hints ---\n\n";
        for my $h (@$hints) {
            print "  $h->{message}\n";
        }
        print "\n";
    }
}


################################################################
# Command builders
################################################################

sub build_clone_cmd {
    my ($job_id) = @_;
    my $cmd = "openqa-clone-job --skip-chained-deps --within-instance \\\n"
        . "    $host/tests/$job_id \\\n";
    if ($casedir) {
        $cmd .= "    CASEDIR='" . $casedir . "' \\\n";
    } else {
        $cmd .= "    CASEDIR='<YOUR_FORK_URL>.git#<YOUR_BRANCH>' \\\n";
    }
    $cmd .= "    BUILD='$build' TEST='$build' _GROUP=0";
    return $cmd;
}

sub build_isos_cmd {
    my ($job) = @_;
    my $cmd = "openqa-cli api --host $host -X POST isos \\\n"
        . "    DISTRI=$job->{distri} VERSION=$job->{version}"
        . " FLAVOR=$job->{flavor} ARCH=$job->{arch} \\\n"
        . "    BUILD='$build'";
    if ($casedir) {
        $cmd .= " \\\n    CASEDIR='" . $casedir . "'";
    }
    return $cmd;
}


################################################################
# Git helpers (adapted from classify_changes.pl)
################################################################

sub get_git_branch {
    my ($dir) = @_;
    my $branch = `git -C '$dir' branch --show-current 2>/dev/null`;
    chomp $branch;
    return $branch || 'HEAD';
}

sub get_git_fork_url {
    my ($dir) = @_;
    for my $remote ('origin', '') {
        my $cmd = $remote
            ? "git -C '$dir' remote get-url '$remote' 2>/dev/null"
            : "git -C '$dir' remote 2>/dev/null";
        if (!$remote) {
            my @remotes = `$cmd`;
            chomp @remotes;
            next unless @remotes;
            $cmd = "git -C '$dir' remote get-url '$remotes[0]' 2>/dev/null";
        }
        my $url = `$cmd`;
        chomp $url;
        next unless $url;
        if ($url =~ m{github\.com[:/](.+?)(?:\.git)?$}) {
            return "https://github.com/$1";
        }
        return $url;
    }
    return undef;
}


################################################################
# Utilities
################################################################

sub min_idx {
    my ($a, $b) = @_;
    return $a < $b ? $a : $b;
}

sub log_verbose {
    my ($msg) = @_;
    print STDERR "[INFO] $msg\n" if $verbose;
}

sub print_usage {
    print <<'EOF';
find_openqa_job.pl — Find openQA jobs to clone for verification runs (VR).

USAGE
    perl find_openqa_job.pl [OPTIONS] SCHEDULE_FILE [SCHEDULE_FILE...]

DESCRIPTION
    Given YAML schedule paths (schedule/*.yml), queries a live openQA
    instance to discover clonable passing jobs and outputs ready-to-use
    openqa-clone-job commands.

    This script does NOT resolve test files (tests/*.pm) to schedules.
    Use find_test_schedule.pl first, then pass the schedule paths here.

    Pipeline:
      1. Query job_settings/jobs API for jobs using each schedule
      2. Sample recent job IDs to discover TEST names and group IDs
      3. Find recent passing jobs for each TEST + group combination
      4. Output clone commands and isos POST commands

HOST (required — pick one)
    --host URL
        Full URL of the openQA instance.
        Example: --host http://openqaworker15.qe.prg2.suse.org

    --osd
        Shorthand for --host http://openqa.suse.de

    --o3
        Shorthand for --host http://openqa.opensuse.org

OPTIONS
    --repo DIR
        Path to the OSADO repository root. Defaults to the current directory.

    --casedir URL#BRANCH
        Override CASEDIR for clone commands. Default: auto-detect from the
        git remote URL and current branch of --repo.

    --build STRING
        Override BUILD for clone commands. Default: auto-detect as
        <github_username>_VR from the git remote. Clone commands also
        use it as TEST.

    --verbose
        Print stage-by-stage progress to stderr.

    --timing
        Measure and report wall-clock time for each openqa-cli API call.
        Prints per-call timing to stderr as each call completes, and a
        summary table at the end. In --json mode, timing data is also
        included in the output under the "timing" key. Useful for
        evaluating server-side cost and identifying optimization targets.

    --json
        Output structured JSON (via JSON::PP) instead of human-readable text.

    --modules NAME
        Programmatic-loader fallback. Instead of resolving YAML schedules,
        query openQA directly for recent passing jobs that ran the given
        module, and emit clone commands for them. Use this for tests loaded
        at runtime via lib/main_*.pm (publiccloud, parts of kernel/LTP) that
        have no static YAML schedule. May be given multiple times. NAME may
        be a tests/*.pm path or a bare module name; it is normalized to the
        openQA module basename (e.g. tests/publiccloud/download_repos.pm →
        download_repos). Fast for commonly-run modules, but can take minutes
        for rarely-run or unknown names — use sparingly.

    --help, -h
        Show this help message and exit.

EXAMPLES
    # Resolve test files to schedules first, then find jobs
    perl find_test_schedule.pl --repo /path/to/osado --json tests/ha/barrier_init.pm \
        | jq -r '.results[].matches[] | select(.type=="yaml_schedule") | .file' \
        | xargs perl find_openqa_job.pl --osd --repo /path/to/osado

    # Find jobs for a YAML schedule on openqa.suse.de
    perl find_openqa_job.pl --osd schedule/sles4sap/cloud-components/ipaddr2.yml

    # Find jobs for a YAML schedule on a specific host
    perl find_openqa_job.pl --host http://openqaworker15.qe.prg2.suse.org \
        schedule/sles4sap/cloud-components/ipaddr2.yml

    # JSON output with custom CASEDIR
    perl find_openqa_job.pl --osd --json \
        --casedir https://github.com/user/repo.git#my_branch \
        schedule/ha/bv/basic_cluster_node.yaml

    # Multiple schedule files
    perl find_openqa_job.pl --osd \
        schedule/sles4sap/hana/hana_cluster_node.yaml \
        schedule/sles4sap/hana/pvm_hana_cluster_node.yaml

    # Measure API call timing for cost analysis
    perl find_openqa_job.pl --osd --timing schedule/ha/bv/basic_cluster_node.yaml

    # Programmatic loader fallback: find jobs by module name (no YAML schedule)
    perl find_openqa_job.pl --osd --modules tests/publiccloud/download_repos.pm

DEPENDENCIES
    External: openqa-cli (from openQA-client package)

SEE ALSO
    find_test_schedule.pl    — Resolve test modules to YAML schedule files
    classify_changes.pl      — Classify changed files and plan testing strategy
EOF
    return 1;
}
