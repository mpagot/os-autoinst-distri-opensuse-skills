#!/usr/bin/perl
# classify_changes.pl — Classify the files committed on the branch and output a testing plan.
# Run with --help for full usage information.

use strict;
use warnings;
use File::Spec;
use File::Basename;
use Getopt::Long;
use Cwd qw(abs_path);
use JSON::PP;

my $repo_dir;
my $verbose = 0;
my $json_output = 0;
my $base;
my $run_helpers = 0;
my $help = 0;

GetOptions(
    'repo=s'          => \$repo_dir,
    'verbose'         => \$verbose,
    'json'            => \$json_output,
    'base=s'          => \$base,
    'helpers'         => \$run_helpers,
    'help|h'          => \$help,
) or do { print_usage(); exit 1 };

print_usage() && exit 0 if $help;

# An openQA VR can only fetch committed code (CASEDIR=fork#branch), so the
# change set is always the branch's commits: no staged/unstaged/file-list modes.
die "Positional file arguments are not supported: the plan covers the commits on\n"
    . "the current branch (BASE...HEAD). Use --base REF to choose the range.\n"
    if @ARGV;

$repo_dir //= '.';
$repo_dir = abs_path($repo_dir);

die "Not a valid OSADO repo: $repo_dir (missing lib/ or tests/)\n"
    unless -d "$repo_dir/lib" && -d "$repo_dir/tests";

# The ref is passed to git as an argument: a leading '-' would be parsed as an option
die "Invalid --base value: '$base'\n"
    if defined $base && $base =~ /^-/;

$base //= find_default_base($repo_dir);
die "Cannot determine the upstream base branch. Pass it with --base REF\n"
    . "  (e.g. --base upstream/master after 'git fetch upstream').\n"
    unless $base;
die "--base '$base' is not a valid commit in $repo_dir\n"
    unless git_ref_exists($repo_dir, $base);
log_verbose("Base: $base");

################################################################
# Get file list
my @changed_files = get_git_files($base);

my @warnings = get_precondition_warnings($repo_dir);

die "No committed changes found in $base...HEAD. Commit your changes first:\n"
    . "  an openQA VR can only run code that is committed and pushed.\n"
    unless @changed_files;

# Normalize paths
@changed_files = map {
    my $f = $_;
    # removes the absolute repository path if the file path starts with it
    # s{...}{} -> "search for the pattern in the first bracket and replace it with nothing"
    #  \Q ... \E treat $repo_dir as literal characters. File paths might contain . or + that have special meanings in regular expressions
    $f =~ s{^\Q$repo_dir\E/}{};
    # turn ./tests/foo.pm into tests/foo.pm
    $f =~ s{^\.\/}{};
    $f;
} @changed_files;

log_verbose("Changed files (" . scalar(@changed_files) . "): " . join(", ", @changed_files));


################################################################
# Classify files
my %categories = (
    tests    => { files => [], vr_needed => 1, label => 'tests/ -- Test modules' },
    lib      => { files => [], vr_needed => 1, label => 'lib/ -- Shared libraries' },
    t        => { files => [], vr_needed => 0, label => 't/ -- Unit tests' },
    data     => { files => [], vr_needed => 1, label => 'data/ -- Static data files' },
    schedule => { files => [], vr_needed => 1, label => 'schedule/ -- YAML schedules' },
    no_vr    => { files => [], vr_needed => 0, label => 'No VR needed' },
);

for my $file (@changed_files) {
    if ($file =~ m{^tests/}) {
        push @{$categories{tests}{files}}, $file;
    } elsif ($file =~ m{^lib/}) {
        push @{$categories{lib}{files}}, $file;
    } elsif ($file =~ m{^t/}) {
        push @{$categories{t}{files}}, $file;
    } elsif ($file =~ m{^data/}) {
        push @{$categories{data}{files}}, $file;
    } elsif ($file =~ m{^schedule/}) {
        push @{$categories{schedule}{files}}, $file;
    } else {
        push @{$categories{no_vr}{files}}, $file;
    }
}


################################################################
# Output
my $branch   = get_git_branch($repo_dir);
my $fork_url = get_git_fork_url($repo_dir);
log_verbose("Resolved branch: $branch");
log_verbose("Resolved fork URL: " . ($fork_url // '(none)'));

my $report = build_report_data(\%categories, \@changed_files, $repo_dir,
    $branch, $fork_url);
$report->{base}     = $base;
$report->{warnings} = \@warnings;

if ($json_output) {
    print_json($report);
} else {
    print_text($report);
}


################################################################
# Run helper scripts if --helpers flag is set
if ($run_helpers) {
    run_helpers(\%categories);
}

exit 0;


sub run_cmd {
    my (@cmd) = @_;
    # A failed exec leaves $? untouched, so die rather than report success
    open(my $fh, "-|", @cmd) or die "Cannot run '$cmd[0]': $!\n";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return @lines;
}


=head2 git_ref_exists

Check whether a git ref resolves to a commit, without printing git errors.

  $ok = git_ref_exists($repo_dir, $ref);

Arguments:

  $repo_dir - Absolute path to the OSADO repository
  $ref      - Ref name or commit hash (e.g. 'upstream/master')

Returns: 1 if the ref resolves to a commit, 0 otherwise.

=cut

sub git_ref_exists {
    my ($repo_dir, $ref) = @_;
    # --quiet keeps a missing ref silent (exit 1, no stderr)
    my @out = run_cmd('git', '-C', $repo_dir, 'rev-parse', '--verify', '--quiet', "$ref^{commit}");
    return ($? == 0 && @out) ? 1 : 0;
}

=head2 find_default_base

Find the master branch that the current branch was forked from.

Candidates are the C<master> branch of the remote pointing to the upstream
C<os-autoinst/os-autoinst-distri-opensuse> repository, C<upstream/master>,
C<origin/master> and the local C<master>. Any of them may be stale (e.g. an
upstream remote that is never fetched while the fork's master is kept in
sync), so the closest one wins: the candidate with the fewest commits in
C<candidate..HEAD>.

  $base = find_default_base($repo_dir);

Arguments:

  $repo_dir - Absolute path to the OSADO repository

Returns: Ref name (e.g. 'origin/master'), or undef if none exists locally.

=cut

sub find_default_base {
    my ($repo_dir) = @_;
    my @candidates;
    for my $remote (run_cmd('git', '-C', $repo_dir, 'remote')) {
        my @url = run_cmd('git', '-C', $repo_dir, 'remote', 'get-url', $remote);
        push @candidates, "$remote/master"
            if @url && $url[0] =~ m{[:/]os-autoinst/os-autoinst-distri-opensuse(?:\.git)?$};
    }
    push @candidates, 'upstream/master', 'origin/master', 'master';

    my ($best, $best_count, %seen);
    for my $ref (grep { !$seen{$_}++ } @candidates) {
        next unless git_ref_exists($repo_dir, $ref);
        my @count = run_cmd('git', '-C', $repo_dir, 'rev-list', '--count', "$ref..HEAD");
        next unless @count && $count[0] =~ /^\d+$/;
        log_verbose("Base candidate $ref: $count[0] commit(s) to HEAD");
        ($best, $best_count) = ($ref, $count[0]) if !defined $best_count || $count[0] < $best_count;
    }
    return $best;
}

=head2 get_git_files

Retrieve the files changed by the commits on the current branch.

Uses C<git diff BASE...HEAD>, which diffs HEAD against the merge-base of
BASE and HEAD: upstream commits made after branching are not included,
and neither are uncommitted changes.

  @files = get_git_files($base);

Arguments:

  $base - Base ref (e.g. 'upstream/master')

Returns: List of repo-relative file paths (Added/Copied/Modified/Renamed only).

Dies on git command failure.

=cut

sub get_git_files {
    my ($base) = @_;
    my @cmd = ('git', '-C', $repo_dir, qw(diff --name-only --diff-filter=ACMR), "$base...HEAD");

    log_verbose("Running: " . join(' ', @cmd));
    my @files = run_cmd(@cmd);
    my $rc = $? >> 8;

    if ($rc != 0) {
        die "git command failed (exit $rc): " . join(' ', @cmd) . "\n";
    }

    return @files;
}

=head2 get_precondition_warnings

Check that the planned change set is what an openQA VR will actually run.

A VR fetches CASEDIR=fork#branch from GitHub, so it only sees commits that
are pushed. Reports (without failing) uncommitted changes to tracked files,
a detached HEAD, a branch that was never pushed, and unpushed commits.

  @warnings = get_precondition_warnings($repo_dir);

Arguments:

  $repo_dir - Absolute path to the OSADO repository

Returns: List of warning strings (empty when everything is pushed).

=cut

sub get_precondition_warnings {
    my ($repo_dir) = @_;
    my @warnings;

    my @dirty = run_cmd('git', '-C', $repo_dir, 'status', '--porcelain', '--untracked-files=no');
    if (@dirty) {
        push @warnings, scalar(@dirty) . " uncommitted change(s) to tracked files are NOT"
            . " part of this plan and will not be in the VR until committed and pushed.";
    }

    my @branch_out = run_cmd('git', '-C', $repo_dir, 'branch', '--show-current');
    my $branch = $branch_out[0] // '';
    if (!$branch) {
        push @warnings, "Detached HEAD: a VR needs a pushed branch for CASEDIR=fork#branch.";
        return @warnings;
    }

    # CASEDIR points to the origin fork (see get_git_fork_url), so compare
    # against origin/<branch> as last fetched rather than the tracking branch.
    my $pushed = "origin/$branch";
    if (!git_ref_exists($repo_dir, $pushed)) {
        push @warnings, "Branch '$branch' is not pushed to origin: run"
            . " 'git push -u origin $branch' before cloning a VR job.";
        return @warnings;
    }

    my @ahead = run_cmd('git', '-C', $repo_dir, 'rev-list', '--count', "$pushed..HEAD");
    if (($ahead[0] // 0) > 0) {
        push @warnings, "$ahead[0] commit(s) on '$branch' are not pushed to '$pushed':"
            . " the VR will run the pushed code, not your local HEAD.";
    }

    return @warnings;
}

=head2 get_git_branch

Resolve the current branch name for use in CASEDIR construction.

  $branch = get_git_branch($repo_dir);

Arguments:

  $repo_dir - Absolute path to the OSADO repository

Returns: Branch name string (e.g. 'my-feature'), or 'HEAD' when detached.

=cut

sub get_git_branch {
    my ($repo_dir) = @_;
    my @branch_out = run_cmd('git', '-C', $repo_dir, 'branch', '--show-current');
    my $branch = $branch_out[0] // '';
    return $branch || 'HEAD';
}

=head2 get_git_fork_url

Resolve the developer's GitHub fork URL from git remotes.

Normalizes SSH and HTTPS remote URLs to a canonical
C<https://github.com/USER/REPO> form for CASEDIR construction.
Tries the 'origin' remote first, then falls back to the first
available remote.

  $url = get_git_fork_url($repo_dir);

Arguments:

  $repo_dir - Absolute path to the OSADO repository

Returns: HTTPS URL string, or undef if no remote is configured.

=cut

sub get_git_fork_url {
    my ($repo_dir) = @_;
    # Try origin first, then any remote
    for my $remote ('origin', '') {
        my $url;
        if ($remote) {
            my @url_out = run_cmd('git', '-C', $repo_dir, 'remote', 'get-url', $remote);
            $url = $url_out[0];
        } else {
            my @remotes = run_cmd('git', '-C', $repo_dir, 'remote');
            next unless @remotes;
            my @url_out = run_cmd('git', '-C', $repo_dir, 'remote', 'get-url', $remotes[0]);
            $url = $url_out[0];
        }
        next unless $url;
        # Normalize: git@github.com:USER/REPO.git or https://github.com/USER/REPO.git
        if ($url =~ m{github\.com[:/](.+?)(?:\.git)?$}) {
            return "https://github.com/$1";
        }
        # Non-GitHub remote: return as-is
        return $url;
    }
    return undef;
}

=head2 find_script

Locate a helper script by filename in the same directory as this script.

  $path = find_script($name);

Arguments:

  $name - Basename of the script to find (e.g. 'find_unit_test.pl')

Returns: Absolute path to the script, or undef if not found.

=cut

sub find_script {
    my ($name) = @_;
    my $dir = dirname(abs_path($0));
    my $path = "$dir/$name";
    return $path if -f $path;
    return undef;
}

=head2 run_helpers

Orchestrate detailed analysis by dispatching to specialized helper scripts
for each non-empty file category.

Mapping:

  tests/    -> find_test_schedule.pl
  lib/      -> find_unit_test.pl + find_affected_tests.pl
               (+ find_test_schedule.pl for function-confirmed targets)
  data/     -> find_data_consumers.pl
  schedule/ -> prints ready-to-run find_openqa_job.pl commands (does NOT execute;
               network access requires user confirmation)

Output is printed directly to stdout.

  run_helpers(\%categories);

Arguments:

  $categories - Hashref of category name => {files => [...], vr_needed => 0|1, label => "..."}

Returns: Nothing (side effects: prints to stdout, may invoke subprocesses).

=cut

sub run_helpers {
    my ($categories) = @_;

    print "\n" . "=" x 60 . "\n";
    print "DETAILED ANALYSIS (--helpers)\n";
    print "=" x 60 . "\n\n";

    # tests/ -> find_test_schedule.pl
    if (@{$categories->{tests}{files}}) {
        my $script = find_script('find_test_schedule.pl');
        if ($script) {
            my @cmd = ('perl', $script, '--repo', $repo_dir);
            push @cmd, '--verbose' if $verbose;
            push @cmd, @{$categories->{tests}{files}};
            log_verbose("Running: " . join(' ', @cmd));
            print "--- find_test_schedule.pl ---\n\n";
            system(@cmd);
            print "\n";
        } else {
            print "  [find_test_schedule.pl not found — skipping]\n\n";
        }
    }

    # lib/ -> find_unit_test.pl + find_affected_tests.pl
    if (@{$categories->{lib}{files}}) {
        my $ut_script = find_script('find_unit_test.pl');
        my $at_script = find_script('find_affected_tests.pl');
        my @files = @{$categories->{lib}{files}};

        if ($ut_script) {
            my @cmd = ('perl', $ut_script, '--repo', $repo_dir);
            push @cmd, '--verbose' if $verbose;
            push @cmd, @files;
            log_verbose("Running: " . join(' ', @cmd));
            print "--- find_unit_test.pl ---\n\n";
            system(@cmd);
            print "\n";
        } else {
            print "  [find_unit_test.pl not found — skipping]\n\n";
        }

        if ($at_script) {
            my @cmd = ('perl', $at_script, '--repo', $repo_dir);
            push @cmd, '--verbose' if $verbose;
            push @cmd, '--base', $base;
            push @cmd, @files;
            log_verbose("Running: " . join(' ', @cmd));
            print "--- find_affected_tests.pl ---\n\n";
            system(@cmd);
            print "\n";

            # Also resolve the function-confirmed test files to YAML schedules
            # automatically.  This closes the full pipeline for lib/ changes so
            # the agent doesn't need to pick between the function-level and
            # module-level lists manually.
            {
                my $ts_script = find_script('find_test_schedule.pl');
                if ($ts_script) {
                    # Run find_affected_tests.pl in JSON mode to extract recommended_tests
                    my @json_cmd = ('perl', $at_script, '--repo', $repo_dir, '--json');
                    push @json_cmd, '--base', $base;
                    push @json_cmd, @files;
                    log_verbose("Running (JSON): " . join(' ', @json_cmd));
                    my $raw;
                    if (open(my $fh, "-|", @json_cmd)) {
                        $raw = do { local $/; <$fh> };
                        close $fh;
                    }
                    if ($raw) {
                        my $data = eval { JSON::PP->new->decode($raw) };
                        my @rec = grep { /^tests\// } @{$data->{recommended_tests} // []};
                        if (!$@ && @rec) {
                            my @ts_cmd = ('perl', $ts_script, '--repo', $repo_dir);
                            push @ts_cmd, '--verbose' if $verbose;
                            push @ts_cmd, @rec;
                            print "--- find_test_schedule.pl (function-confirmed VR targets) ---\n\n";
                            log_verbose("Running: " . join(' ', @ts_cmd));
                            system(@ts_cmd);
                            print "\n";
                        }
                    }
                }
            }
        } else {
            print "  [find_affected_tests.pl not found — skipping]\n\n";
        }
    }

    # data/ -> find_data_consumers.pl
    if (@{$categories->{data}{files}}) {
        my $script = find_script('find_data_consumers.pl');
        if ($script) {
            my @cmd = ('perl', $script, '--repo', $repo_dir);
            push @cmd, '--verbose' if $verbose;
            push @cmd, @{$categories->{data}{files}};
            log_verbose("Running: " . join(' ', @cmd));
            print "--- find_data_consumers.pl ---\n\n";
            system(@cmd);
            print "\n";
        } else {
            print "  [find_data_consumers.pl not found — skipping]\n\n";
        }
    }

    # schedule/ -> find_openqa_job.pl
    # find_openqa_job.pl requires a --host/--osd/--o3 flag that we cannot
    # determine automatically, so we print the ready-to-run command rather than
    # executing it directly.
    if (@{$categories->{schedule}{files}}) {
        my $script = find_script('find_openqa_job.pl');
        my $files  = join(' ', sort @{$categories->{schedule}{files}});
        print "--- find_openqa_job.pl ---\n\n";
        if ($script) {
            print "  (requires network access — specify --host, --osd, or --o3)\n\n";
            print "  # For openqa.suse.de (SLE/SLE Micro):\n";
            print "  perl '$script' --osd --repo '$repo_dir' $files\n\n";
            print "  # For openqa.opensuse.org (Tumbleweed/Leap):\n";
            print "  perl '$script' --o3 --repo '$repo_dir' $files\n\n";
        } else {
            print "  [find_openqa_job.pl not found — skipping]\n\n";
        }
    }
}

=head2 build_report_data

Assemble the classification results into a single report hashref for rendering.

Computes the aggregate count of files needing a verification run and bundles
the git metadata alongside the categorized file lists.

  $report = build_report_data(\%categories, \@changed_files, $repo_dir, $branch, $fork_url);

Arguments:

  $categories    - Hashref of classified file categories
  $changed_files - Arrayref of all changed file paths
  $repo_dir      - Absolute path to the OSADO repository
  $branch        - Resolved branch name
  $fork_url      - Resolved GitHub fork URL (may be undef)

Returns: Hashref with keys: total_files, total_vr_needed, categories, repo_dir, branch, fork_url.

=cut

# --- Data preparation ---

sub build_report_data {
    my ($categories, $changed_files, $repo_dir, $branch, $fork_url) = @_;
    my $vr_needed = 0;
    for my $cat (values %$categories) {
        $vr_needed += scalar @{$cat->{files}}
            if $cat->{vr_needed} && @{$cat->{files}};
    }
    return {
        total_files     => scalar(@$changed_files),
        total_vr_needed => $vr_needed,
        categories      => $categories,
        repo_dir        => $repo_dir,
        branch          => $branch,
        fork_url        => $fork_url,
    };
}

=head2 print_text

Render the classification report as human-readable terminal output.

Prints per-category file listings with VR indicators, actionable guidance
for each category, and a summary section with copy-paste-ready commands
(prove for unit tests, openqa-clone-job for VR).

  print_text($report);

Arguments:

  $report - Hashref as returned by build_report_data()

Returns: Nothing (prints to stdout).

=cut

# --- Output functions ---

sub print_text {
    my ($report) = @_;
    my $categories = $report->{categories};
    my $repo_dir   = $report->{repo_dir};

    print "=" x 60, "\n";
    print "OSADO Change Classification & Testing Plan\n";
    print "=" x 60, "\n\n";

    print "Change set: commits in $report->{base}...HEAD (branch $report->{branch})\n";
    print "Total files changed: $report->{total_files}\n";
    print "Files needing openQA VR: $report->{total_vr_needed}\n\n";

    if (@{$report->{warnings}}) {
        print "WARNINGS:\n";
        print "  ! $_\n" for @{$report->{warnings}};
        print "\n";
    }

    # Print each non-empty category
    my @order = qw(tests lib t data schedule no_vr);
    for my $cat_name (@order) {
        my $cat = $categories->{$cat_name};
        next unless @{$cat->{files}};

        my $vr_tag = $cat->{vr_needed} ? " [VR NEEDED]" : " [No VR]";
        print "-" x 50, "\n";
        print "$cat->{label}$vr_tag (" . scalar(@{$cat->{files}}) . " files)\n";
        print "-" x 50, "\n\n";

        for my $file (sort @{$cat->{files}}) {
            print "  $file\n";
        }
        print "\n";

        # Category-specific guidance
        my $guidance = get_guidance($cat_name, $cat->{files}, $repo_dir);
        print "  $_\n" for @$guidance;
        print "\n";
    }

    # Summary
    print "=" x 60, "\n";
    print "SUMMARY\n";
    print "=" x 60, "\n\n";

    if (@{$categories->{t}{files}}) {
        print "1. Run unit tests locally:\n";
        for my $f (sort @{$categories->{t}{files}}) {
            print "   PERL5OPT=-MCarp::Always prove --time --verbose -l -Ios-autoinst/ $f\n";
        }
        print "\n";
    }

    if (@{$categories->{lib}{files}}) {
        print "2. Run this helper script to find which unit tests are associated to changed lib modules:\n";
        print "   perl find_unit_test.pl --repo $repo_dir " .
            join(' ', sort @{$categories->{lib}{files}}) . "\n";
        print "   (or: make unit-test)\n\n";
    }

    if ($report->{total_vr_needed} > 0) {
        my $casedir = $report->{fork_url}
            ? "$report->{fork_url}.git#$report->{branch}"
            : "https://github.com/USER/os-autoinst-distri-opensuse.git#$report->{branch}";
        print "3. Run openQA verification (VR):\n";
        print "   # First, find a passing production job to clone. Example:\n";
        print "   # openqa-cli api --host HOST jobs groupid=GROUP_ID test=TEST_NAME \\\n";
        print "   #   state=done result=passed latest=1\n";
        print "   #\n";
        print "   # Then clone it:\n";
        print "   openqa-clone-job --skip-chained-deps --within-instance \\\n";
        print "     http://HOST/tests/JOB_ID \\\n";
        print "     CASEDIR=$casedir \\\n";
        print "     BUILD=user_VR TEST=user_VR _GROUP=0\n\n";
    }

    if ($run_helpers) {
        # Detailed analysis already printed above
    } else {
        print "Tip: Re-run with --helpers for detailed analysis using helper scripts.\n";
    }
}

=head2 get_guidance

Generate category-specific "next action" lines for display or JSON output.

Maps each category to the recommended verification command(s) the developer
should run next.

  $lines = get_guidance($cat_name, $files, $repo_dir);

Arguments:

  $cat_name - Category key: 'tests', 'lib', 't', 'data', 'schedule', or 'no_vr'
  $files    - Arrayref of file paths in this category
  $repo_dir - Absolute path to the OSADO repository

Returns: Arrayref of guidance strings (one per output line).

=cut

sub get_guidance {
    my ($cat_name, $files, $repo_dir) = @_;
    my @sorted = sort @$files;
    my @lines;

    if ($cat_name eq 'tests') {
        push @lines, "Action: Clone an openQA job that runs each test module.";
        push @lines, "Find the schedule: perl find_test_schedule.pl --repo $repo_dir "
            . join(' ', @sorted);
    } elsif ($cat_name eq 'lib') {
        push @lines, "Action: (1) Run unit tests, (2) Clone an openQA job.";
        push @lines, "Find unit tests: perl find_unit_test.pl --repo $repo_dir "
            . join(' ', @sorted);
        push @lines, "Find affected tests: perl find_affected_tests.pl --repo $repo_dir "
            . "--base $base " . join(' ', @sorted);
    } elsif ($cat_name eq 't') {
        push @lines, "Action: Run these test files locally.";
        for my $f (@sorted) {
            push @lines,
                "PERL5OPT=-MCarp::Always prove --time --verbose -l -Ios-autoinst/ $f";
        }
    } elsif ($cat_name eq 'data') {
        push @lines, "Action: Clone a job that uses the data file.";
        push @lines, "Find consumers: perl find_data_consumers.pl --repo $repo_dir "
            . join(' ', @sorted);
    } elsif ($cat_name eq 'schedule') {
        push @lines, "Action: Clone a job that uses the modified schedule.";
        for my $f (@sorted) {
            push @lines,
                "openqa-cli api --osd job_settings/jobs key=YAML_SCHEDULE value=$f";
        }
    } elsif ($cat_name eq 'no_vr') {
        push @lines, "Action: No openQA verification needed.";
        push @lines, "Consider running: make test";
    }

    return \@lines;
}

=head2 print_json

Render the classification report as pretty-printed JSON for machine consumption.

Produces a structure with keys: total_files, total_vr_needed, branch, base,
fork_url, warnings, and categories (each with label, vr_needed, files, guidance).

  print_json($report);

Arguments:

  $report - Hashref as returned by build_report_data()

Returns: Nothing (prints JSON to stdout).

=cut

sub print_json {
    my ($report) = @_;
    my $categories = $report->{categories};

    my %out = (
        total_files     => $report->{total_files},
        total_vr_needed => $report->{total_vr_needed},
        branch          => $report->{branch},
        base            => $report->{base},
        fork_url        => $report->{fork_url},
        warnings        => $report->{warnings},
        categories      => {},
    );

    my @order = qw(tests lib t data schedule no_vr);
    for my $name (@order) {
        my $cat = $categories->{$name};
        next unless @{$cat->{files}};
        my $guidance = get_guidance($name, $cat->{files}, $report->{repo_dir});
        $out{categories}{$name} = {
            label     => $cat->{label},
            vr_needed => $cat->{vr_needed} ? JSON::PP::true : JSON::PP::false,
            files     => [sort @{$cat->{files}}],
            guidance  => $guidance,
        };
    }

    print JSON::PP->new->pretty->canonical->encode(\%out);
}

=head2 log_verbose

Print a diagnostic message to stderr when verbose mode is active.

  log_verbose($msg);

Arguments:

  $msg - Message string to print

Returns: Nothing.

=cut

sub log_verbose {
    my ($msg) = @_;
    print STDERR "[INFO] $msg\n" if $verbose;
}

sub print_usage {
    print <<'EOF';
classify_changes.pl — Classify committed changes and output an OSADO testing plan.

USAGE
    perl classify_changes.pl [OPTIONS]

DESCRIPTION
    Takes the files changed by the commits on the current branch
    (git diff BASE...HEAD), categorizes each file by its location in the
    os-autoinst-distri-opensuse repository and outputs the appropriate
    testing strategy:

        tests/     → Clone an openQA job (VR needed)
        lib/       → Run unit tests + clone an openQA job (VR needed)
        t/         → Run locally with prove (no VR)
        data/      → Clone a job that uses the data file (VR needed)
        schedule/  → Clone a job that uses the schedule (VR needed)
        other      → No openQA verification needed

CHANGE SET
    An openQA VR fetches the code from CASEDIR=fork#branch, so it can only
    run what is committed and pushed. The plan therefore covers only the
    commits on the current branch; staged, unstaged and untracked changes
    are ignored. The report warns (without failing) about uncommitted
    changes to tracked files, a detached HEAD, a branch not pushed to
    origin, and unpushed commits.

    --base REF
        Ref the branch was forked from. Defaults to the closest of: the
        master branch of the remote pointing to
        os-autoinst/os-autoinst-distri-opensuse, upstream/master,
        origin/master and master (the one with the fewest commits to HEAD,
        so a stale, never-fetched remote is not picked).

OPTIONS
    --repo DIR
        Path to the OSADO repository root. Defaults to the current directory.
        The directory must contain lib/ and tests/ subdirectories.

    --helpers
        After classification, automatically invoke the specialized helper
        scripts for each category to produce detailed analysis:
          - find_test_schedule.pl   for tests/ files
          - find_unit_test.pl       for lib/ files
          - find_affected_tests.pl  for lib/ files
          - find_data_consumers.pl  for data/ files

    --verbose
        Print extra diagnostic information to stderr. When --helpers is also
        set, passes --verbose to each helper script.

    --json
        Output the classification as JSON instead of human-readable text.

    --help, -h
        Show this help message and exit.

EXAMPLES
    # Classify the commits on the current branch (default base)
    perl classify_changes.pl --repo /path/to/osado

    # Classify against an explicit base
    perl classify_changes.pl --repo /path/to/osado --base upstream/master

    # Full analysis with helper scripts
    perl classify_changes.pl --repo /path/to/osado --helpers --verbose

SEE ALSO
    find_test_schedule.pl, find_affected_tests.pl, find_unit_test.pl,
    find_data_consumers.pl
EOF
    return 1;
}
