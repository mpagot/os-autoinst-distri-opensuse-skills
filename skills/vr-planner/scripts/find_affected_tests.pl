#!/usr/bin/perl
# find_affected_tests.pl — Find test files affected by changes to lib/ modules.
# Run with --help for full usage information.

use strict;
use warnings;
use File::Find;
use File::Spec;
use File::Temp qw(tempfile);
use Getopt::Long;
use JSON::PP;

my $repo_dir;
my $verbose = 0;
my $json_output = 0;
my $base;
my $help = 0;

GetOptions(
    'repo=s'       => \$repo_dir,
    'verbose'      => \$verbose,
    'json'         => \$json_output,
    'base=s'       => \$base,
    'help|h'       => \$help,
) or do { print_usage(); exit 1 };

print_usage() && exit 0 if $help;

# Default repo dir: current directory
unless ($repo_dir) {
    $repo_dir = '.';
}

# Resolve to absolute path so File::Find returns absolute $File::Find::name
# (File::Find chdirs into subdirs during traversal; relative starting paths
# make $File::Find::name relative and invalid from inner chdir contexts).
$repo_dir = File::Spec->rel2abs($repo_dir);

die "Not a valid OSADO repo: $repo_dir (missing lib/ or tests/)\n"
    unless -d "$repo_dir/lib" && -d "$repo_dir/tests";

# The ref is passed to git as an argument: a leading '-' would be parsed as an option
die "Invalid --base value: '$base'\n"
    if defined $base && $base =~ /^-/;

sub run_cmd {
    my (@cmd) = @_;
    # A failed exec leaves $? untouched, so die rather than report success
    open(my $fh, "-|", @cmd) or die "Cannot run '$cmd[0]': $!\n";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return @lines;
}

my @input_paths = @ARGV;

# If --base is given without explicit file args, auto-derive the lib/ files
# committed on the branch (BASE...HEAD) so the caller doesn't have to supply them.
if (!@input_paths && $base) {
    my @changed = run_cmd('git', '-C', $repo_dir, 'diff', '--name-only', "$base...HEAD");
    @input_paths = grep { m{^lib/.*\.pm$} } @changed;
    die "No lib/*.pm files committed in $base...HEAD\n" unless @input_paths;
}

die "Usage: $0 [--repo DIR] [--verbose] [--json] [--base REF] lib/A/B.pm ...\n"
    unless @input_paths;
# --- Step 1: Convert file paths to package names ---

sub path_to_pkg {
    my ($path) = @_;
    # Normalize: strip leading ./ or repo_dir prefix
    $path =~ s{^\Q$repo_dir\E/}{};
    $path =~ s{^\.\/}{};
    $path =~ s{^lib/}{};
    $path =~ s{\.pm$}{};
    $path =~ s{/}{::}g;
    return $path;
}

my @target_pkgs;
for my $path (@input_paths) {
    unless ($path =~ m{(?:^|/)lib/.*\.pm$} || $path =~ m{^[^/]+.*\.pm$}) {
        warn "Warning: '$path' does not look like a lib/*.pm path, skipping\n";
        next;
    }
    push @target_pkgs, path_to_pkg($path);
}
die "No valid lib/*.pm paths provided\n" unless @target_pkgs;

log_verbose("Target packages: " . join(", ", @target_pkgs));

# --- Step 2: Build dependency maps ---

# Discover all lib/ packages (pkg_name => relative file path)
my %lib_files;
find(sub {
    return unless /\.pm$/ && -f;
    my $rel = File::Spec->abs2rel($File::Find::name, $repo_dir);
    my $pkg = path_to_pkg($rel);
    $lib_files{$pkg} = $rel;
}, "$repo_dir/lib");

log_verbose("Found " . scalar(keys %lib_files) . " lib modules");

# Validate target packages exist
for my $pkg (@target_pkgs) {
    unless (exists $lib_files{$pkg}) {
        warn "Warning: package '$pkg' not found in lib/ — will still trace dependents\n";
    }
}

# Extract imports from a file. Returns list of OSADO lib package names.
sub extract_imports {
    my ($filepath) = @_;
    my @imports;

    open my $fh, '<', $filepath or do {
        warn "Cannot open $filepath: $!\n";
        return @imports;
    };

    my $in_mojo_qw = 0;    # state: inside use Mojo::Base qw( ... )

    while (my $line = <$fh>) {
        chomp $line;

        # Skip comments and POD
        next if $line =~ /^\s*#/;
        next if $line =~ /^=(pod|head|over|item|back|begin|end|for|encoding|cut)\b/;

        # State: collecting Mojo::Base qw() parents across lines
        if ($in_mojo_qw) {
            if ($line =~ /\)/) {
                # Extract any packages before the closing paren
                my ($before) = $line =~ /^(.*?)\)/;
                for my $word (split /\s+/, $before // '') {
                    $word =~ s/^\s+|\s+$//g;
                    push @imports, $word if $word =~ /::/ && exists $lib_files{$word};
                }
                $in_mojo_qw = 0;
            } else {
                for my $word (split /\s+/, $line) {
                    $word =~ s/^\s+|\s+$//g;
                    push @imports, $word if $word =~ /::/ && exists $lib_files{$word};
                }
            }
            next;
        }

        # Pattern: use Mojo::Base 'Parent::Class';
        if ($line =~ /use\s+Mojo::Base\s+'([^']+)'/) {
            my $parent = $1;
            push @imports, $parent if exists $lib_files{$parent};
            next;
        }

        # Pattern: use Mojo::Base "Parent::Class";
        if ($line =~ /use\s+Mojo::Base\s+"([^"]+)"/) {
            my $parent = $1;
            push @imports, $parent if exists $lib_files{$parent};
            next;
        }

        # Pattern: use Mojo::Base qw(...) — single line
        if ($line =~ /use\s+Mojo::Base\s+qw\(([^)]+)\)/) {
            for my $word (split /\s+/, $1) {
                $word =~ s/^\s+|\s+$//g;
                push @imports, $word if $word && exists $lib_files{$word};
            }
            next;
        }

        # Pattern: use Mojo::Base qw( — multiline start
        if ($line =~ /use\s+Mojo::Base\s+qw\((.*)$/) {
            my $rest = $1;
            for my $word (split /\s+/, $rest) {
                $word =~ s/^\s+|\s+$//g;
                push @imports, $word if $word && exists $lib_files{$word};
            }
            $in_mojo_qw = 1;
            next;
        }

        # Pattern: use Pkg::Name ...  (bare, with qw, with 'func', etc.)
        # We only need the package name, not the imported symbols.
        if ($line =~ /^\s*use\s+([\w:]+)/) {
            my $pkg = $1;
            # Skip Mojo::Base (handled above), pragmas, and core/CPAN modules
            next if $pkg eq 'Mojo::Base';
            next if $pkg eq 'base' || $pkg eq 'parent';
            next unless exists $lib_files{$pkg};
            push @imports, $pkg;
            next;
        }

        # Pattern: require Pkg::Name;
        if ($line =~ /require\s+([\w:]+)\s*;/) {
            my $pkg = $1;
            push @imports, $pkg if exists $lib_files{$pkg};
            next;
        }
    }

    close $fh;

    # Deduplicate
    my %seen;
    return grep { !$seen{$_}++ } @imports;
}

# Build forward and reverse dependency maps for lib/ modules
my %lib_deps;       # pkg => { dep_pkg => 1 }
my %reverse_lib;    # pkg => { importer_pkg => 1 }

for my $pkg (sort keys %lib_files) {
    my @deps = extract_imports("$repo_dir/$lib_files{$pkg}");
    $lib_deps{$pkg} = { map { $_ => 1 } @deps };
    for my $dep (@deps) {
        $reverse_lib{$dep}{$pkg} = 1;
    }
}

log_verbose("Built lib dependency graph: " . scalar(keys %lib_deps) . " nodes");

# Scan tests/ for imports
my %test_deps;    # test_file => { dep_pkg => 1 }

find(sub {
    return unless /\.pm$/ && -f;
    my $rel = File::Spec->abs2rel($File::Find::name, $repo_dir);
    my @deps = extract_imports($File::Find::name);
    $test_deps{$rel} = { map { $_ => 1 } @deps } if @deps;
}, "$repo_dir/tests");

log_verbose("Scanned " . scalar(keys %test_deps) . " test files with dependencies");

# --- Step 2b: Function-level analysis (when --base is provided) ---

# Build a sub boundary map for a file: returns arrayref of
# { name => 'sub_name', start => N, end => N } sorted by start line.
# Lines outside any sub are not covered.
sub build_sub_map {
    my ($filepath) = @_;
    my @subs;

    open my $fh, '<', $filepath or do {
        warn "Cannot open $filepath: $!\n";
        return [];
    };

    my $in_pod = 0;
    my @stack;    # stack of { name, start, depth }

    while (my $line = <$fh>) {
        my $lineno = $.;
        chomp $line;

        # Track POD sections
        if ($line =~ /^=(pod|head|over|item|back|begin|end|for|encoding)\b/) {
            $in_pod = 1;
            next;
        }
        if ($line =~ /^=cut\b/) {
            $in_pod = 0;
            next;
        }
        next if $in_pod;

        # Detect sub declaration
        if ($line =~ /^\s*sub\s+(\w+)/) {
            my $name = $1;
            # Count opening braces on this line to initialize depth
            my $opens = () = $line =~ /\{/g;
            my $closes = () = $line =~ /\}/g;
            my $depth = $opens - $closes;
            if ($depth > 0) {
                push @stack, { name => $name, start => $lineno, depth => $depth };
            } elsif ($opens > 0 && $depth == 0) {
                # One-liner sub: sub foo { ... }
                push @subs, { name => $name, start => $lineno, end => $lineno };
            }
            # depth < 0 shouldn't happen in well-formed code
            next;
        }

        # Track brace depth for current sub(s)
        if (@stack) {
            my $opens = () = $line =~ /\{/g;
            my $closes = () = $line =~ /\}/g;
            $stack[-1]{depth} += $opens - $closes;
            while (@stack && $stack[-1]{depth} <= 0) {
                my $completed = pop @stack;
                push @subs, {
                    name  => $completed->{name},
                    start => $completed->{start},
                    end   => $lineno,
                };
            }
        }
    }

    close $fh;

    # Sort by start line
    @subs = sort { $a->{start} <=> $b->{start} } @subs;
    return \@subs;
}

# Given a sub map and a line number, find the enclosing sub name.
# Returns undef if the line is outside any sub.
sub find_enclosing_sub {
    my ($sub_map, $lineno) = @_;
    for my $s (@$sub_map) {
        return $s->{name} if $lineno >= $s->{start} && $lineno <= $s->{end};
    }
    return undef;
}

# Classify diff hunks for a specific file committed on the branch (BASE...HEAD).
# Returns a hashref:
#   { functions => { func_name => 1, ... },
#     module_scope => [ "description of module-scope change", ... ],
#     inert => 0 or 1 }
sub classify_diff_hunks {
    my ($repo_dir, $base, $file_path) = @_;

    my %result = (functions => {}, module_scope => [], inert => 1);

    # Get the diff to parse hunk line numbers. BASE...HEAD diffs HEAD against
    # the merge-base, so upstream commits made after branching are excluded.
    my @diff_cmd = ('git', '-C', $repo_dir, 'diff', "$base...HEAD", '--', $file_path);
    log_verbose("Running: " . join(' ', @diff_cmd));
    my @diff_lines = run_cmd(@diff_cmd);

    return \%result unless @diff_lines;

    # Build the sub map from the NEW version of the file: the committed HEAD,
    # not the working tree, because that is what an openQA VR will run.
    my @show_cmd = ('git', '-C', $repo_dir, 'show', "HEAD:$file_path");
    log_verbose("Running: " . join(' ', @show_cmd));
    my @file_content = run_cmd(@show_cmd);

    # Write to a temp file for build_sub_map; File::Temp auto-deletes on scope exit.
    my ($tfh, $tmpfile) = tempfile(SUFFIX => '.pm', UNLINK => 1);
    print $tfh "$_\n" for @file_content;
    close $tfh;

    my $sub_map = build_sub_map($tmpfile);

    log_verbose("Sub map for $file_path: " . scalar(@$sub_map) . " subs found");

    # Parse diff hunks: extract the new-file line ranges from @@ headers
    # and classify each changed line
    my $current_new_line = 0;
    my $in_hunk = 0;

    for my $line (@diff_lines) {
        # Hunk header: @@ -old_start[,old_count] +new_start[,new_count] @@
        if ($line =~ /^\@\@\s+\-\d+(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+\@\@/) {
            $current_new_line = $1;
            $in_hunk = 1;
            next;
        }

        next unless $in_hunk;

        # Lines starting with '-' are deletions (old file) — don't advance new line counter
        if ($line =~ /^-/) {
            # Deleted lines: classify using the NEW file's sub map at the
            # current position (the deletion happened "at" this line in context)
            my $is_inert = ($line =~ /^-\s*#/ || $line =~ /^-\s*$/
                         || $line =~ /^-\s*=\w/);
            unless ($is_inert) {
                my $sub_name = find_enclosing_sub($sub_map, $current_new_line);
                if ($sub_name) {
                    $result{functions}{$sub_name} = 1;
                } else {
                    # Classify what kind of module-scope change this is
                    my $content = $line;
                    $content =~ s/^-\s*//;
                    push @{$result{module_scope}}, classify_module_line($content);
                }
                $result{inert} = 0;
            }
            next;
        }

        # Lines starting with '+' are additions (new file)
        if ($line =~ /^\+/) {
            my $is_inert = ($line =~ /^\+\s*#/ || $line =~ /^\+\s*$/
                         || $line =~ /^\+\s*=\w/);
            unless ($is_inert) {
                my $sub_name = find_enclosing_sub($sub_map, $current_new_line);
                if ($sub_name) {
                    $result{functions}{$sub_name} = 1;
                } else {
                    my $content = $line;
                    $content =~ s/^\+\s*//;
                    push @{$result{module_scope}}, classify_module_line($content);
                }
                $result{inert} = 0;
            }
            $current_new_line++;
            next;
        }

        # Context line (starts with space): advance new line counter
        $current_new_line++;
    }

    return \%result;
}

# Describe what kind of module-scope line this is
sub classify_module_line {
    my ($line) = @_;
    return '@EXPORT list'          if $line =~ /EXPORT/;
    return 'use/require statement' if $line =~ /^\s*(use|require)\s/;
    return 'constant declaration'  if $line =~ /use\s+constant\s/;
    return 'package variable'      if $line =~ /^\s*(my|our|local)\s/;
    return 'package declaration'   if $line =~ /^\s*package\s/;
    return 'module-scope code';
}

# Decide whether a source line calls $func_name defined in package $pkg.
# $bare_ok is true when the file may call it unqualified (same package or
# imports $pkg). Each occurrence of the name is classified by its prefix:
#   ->func              method call, class unknown: accepted
#   Pkg::func           accepted only if Pkg is $pkg (another package's
#                       same-named function otherwise)
#   func / &func        accepted only if $bare_ok
#   sub func            the definition, never a call
sub line_calls_function {
    my ($line, $func_name, $pkg, $bare_ok) = @_;
    while ($line =~ /(->\s*|\bsub\s+)?((?:\w+::)*)\b\Q$func_name\E\b/g) {
        my ($prefix, $qualifier) = ($1 // '', $2);
        next if $prefix =~ /sub/;
        return 1 if $prefix;
        if ($qualifier ne '') {
            $qualifier =~ s/::$//;
            return 1 if $qualifier eq $pkg;
            next;
        }
        return 1 if $bare_ok;
    }
    return 0;
}

# Find all callers of function $func_name (defined in package $pkg) across
# the specified directories.
# Returns arrayref of { file => rel_path, line => N, context => "line content" }
sub find_function_callers {
    my ($func_name, $pkg, @search_dirs) = @_;
    my @callers;

    for my $dir (@search_dirs) {
        find(sub {
            return unless /\.pm$/ && -f;
            my $abs_path = $File::Find::name;
            my $rel = File::Spec->abs2rel($abs_path, $repo_dir);

            # Unqualified calls resolve only inside $pkg itself or in files importing it
            my $imports = $rel =~ m{^lib/} ? $lib_deps{path_to_pkg($rel)} : $test_deps{$rel};
            my $bare_ok = ($rel =~ m{^lib/} && path_to_pkg($rel) eq $pkg)
                || ($imports && $imports->{$pkg});

            open my $fh, '<', $abs_path or return;
            while (my $line = <$fh>) {
                if ($line !~ /^\s*#/ && $line !~ /EXPORT/
                    && line_calls_function($line, $func_name, $pkg, $bare_ok)) {
                    chomp $line;
                    $line =~ s/^\s+//;
                    push @callers, { file => $rel, line => $., context => $line };
                }
            }
            close $fh;
        }, $dir);
    }

    return \@callers;
}

# Subs where the upward walk stops: openQA test hooks, constructors and
# schedule loaders (load_*). Their callers are the test runner or the whole
# schedule, so following them would reach nearly every test.
my $ENTRY_POINT_RE = qr/^(?:run|pre_run_hook|post_run_hook|post_fail_hook|test_flags|new|load_\w+)$/;

# Walk transitive function-level callers through lib/.
# Starting from a set of function names defined in $root_pkg, find callers
# in lib/, determine which sub contains each call site, then find callers
# of *those* subs, and so on (BFS). Entry-point subs are recorded but not
# followed.
# Returns:
#   { func_name => [caller entries from tests/ and lib/] }
sub find_transitive_function_callers {
    my ($root_pkg, @root_funcs) = @_;

    my %all_callers;     # func_name => [caller entries from tests/ and lib/]
    my %visited_funcs;   # "pkg::func" already processed
    my @queue = map { [$root_pkg, $_] } @root_funcs;

    while (@queue) {
        my ($pkg, $func) = @{shift @queue};
        next if $visited_funcs{"${pkg}::$func"}++;

        my $callers = find_function_callers($func, $pkg,
            "$repo_dir/tests", "$repo_dir/lib");
        push @{$all_callers{$func}}, @$callers;

        # For callers found in lib/, identify the enclosing sub.
        # If it's a new function we haven't visited, enqueue it.
        for my $caller (@$callers) {
            next unless $caller->{file} =~ m{^lib/};
            my $sub_map = build_sub_map("$repo_dir/$caller->{file}");
            my $enclosing = find_enclosing_sub($sub_map, $caller->{line});
            $caller->{enclosing_sub} = $enclosing;
            next unless $enclosing;
            if ($enclosing =~ $ENTRY_POINT_RE) {
                $caller->{entry_point} = 1;
                next;
            }
            my $caller_pkg = path_to_pkg($caller->{file});
            push @queue, [$caller_pkg, $enclosing]
                unless $visited_funcs{"${caller_pkg}::$enclosing"};
        }
    }

    return \%all_callers;
}

# --- Function-level analysis orchestration ---

my %func_analysis;    # Will hold function-level results if available
my $has_func_analysis = 0;

if ($base) {
    log_verbose("Performing function-level analysis for $base...HEAD");

    for my $path (@input_paths) {
        my $rel = $path;
        $rel =~ s{^\Q$repo_dir\E/}{};
        $rel =~ s{^\.\/}{};

        my $classification = classify_diff_hunks($repo_dir, $base, $rel);

        my @func_names = sort keys %{$classification->{functions}};
        my @mod_scope  = @{$classification->{module_scope}};

        $func_analysis{$rel} = {
            changed_functions => \@func_names,
            module_scope      => \@mod_scope,
            inert             => $classification->{inert},
        };

        if (@func_names) {
            log_verbose("Changed functions in $rel: " . join(", ", @func_names));
            my $callers = find_transitive_function_callers(path_to_pkg($rel), @func_names);
            $func_analysis{$rel}{callers} = $callers;

            # Count test callers
            my %test_files;
            for my $func (keys %$callers) {
                for my $c (@{$callers->{$func}}) {
                    $test_files{$c->{file}} = 1 if $c->{file} =~ m{^tests/};
                }
            }
            log_verbose("Function-level: " . scalar(keys %test_files)
                . " test files call changed functions");
        }

        if (@mod_scope) {
            log_verbose("Module-scope changes in $rel: " . join(", ", @mod_scope));
        }

        $has_func_analysis = 1;
    }
}

# --- Step 3: Walk transitive lib dependents ---

sub find_transitive_dependents {
    my (@roots) = @_;
    my %visited;
    my %chains;    # pkg => [chain from root to this pkg]

    my @queue;
    for my $root (@roots) {
        $visited{$root} = 1;
        $chains{$root} = [$root];
        push @queue, $root;
    }

    while (@queue) {
        my $current = shift @queue;
        next unless exists $reverse_lib{$current};
        for my $dependent (sort keys %{$reverse_lib{$current}}) {
            next if $visited{$dependent};
            # Only follow lib-to-lib edges (not test consumers)
            next unless exists $lib_files{$dependent};
            $visited{$dependent} = 1;
            $chains{$dependent} = [@{$chains{$current}}, $dependent];
            push @queue, $dependent;
        }
    }

    return (\%visited, \%chains);
}

my ($expanded_set, $chains) = find_transitive_dependents(@target_pkgs);

# --- Step 4: Collect affected tests ---

my %affected_tests;    # test_file => [list of packages that connect it]

for my $test_file (sort keys %test_deps) {
    for my $dep (keys %{$test_deps{$test_file}}) {
        if ($expanded_set->{$dep}) {
            push @{$affected_tests{$test_file}}, $dep;
        }
    }
}

# --- Step 5: Output ---

my %is_target = map { $_ => 1 } @target_pkgs;
my @transitive_pkgs = sort grep { !$is_target{$_} } keys %$expanded_set;

# Build func_analysis reference (undef if no --base)
my $fa_ref = $has_func_analysis ? \%func_analysis : undef;

if ($json_output) {
    print_json(\@target_pkgs, \@transitive_pkgs, \%affected_tests, $chains, $fa_ref);
} else {
    print_text(\@target_pkgs, \@transitive_pkgs, \%affected_tests, $chains, $fa_ref);
}

exit 0;

# --- Output functions ---

sub print_text {
    my ($targets, $transitive, $tests, $chains, $func_analysis) = @_;

    print "=" x 60, "\n";
    print "Affected tests for: ", join(", ", map { $lib_files{$_} // $_ } @$targets), "\n";
    print "=" x 60, "\n\n";

    # --- Function-level tier (when available) ---
    if ($func_analysis) {
        for my $file (sort keys %$func_analysis) {
            my $fa = $func_analysis->{$file};
            my @funcs = @{$fa->{changed_functions}};
            my @mod   = @{$fa->{module_scope}};

            if (@funcs) {
                print "Changed functions: ", join(", ", @funcs), "\n\n";

                # Collect test callers across all functions
                my %func_test_files;    # test_file => [func names]
                my %func_lib_callers;   # func => [lib caller entries]
                if ($fa->{callers}) {
                    for my $func (sort keys %{$fa->{callers}}) {
                        for my $c (@{$fa->{callers}{$func}}) {
                            if ($c->{file} =~ m{^tests/}) {
                                push @{$func_test_files{$c->{file}}}, {
                                    func => $func, line => $c->{line},
                                    context => $c->{context},
                                };
                            } else {
                                push @{$func_lib_callers{$func}}, $c;
                            }
                        }
                    }
                }

                my $n_test = scalar keys %func_test_files;
                print "=" x 60, "\n";
                print "VR-CONFIRMED TARGETS — function-level callers ($n_test test files):\n";
                print "=" x 60, "\n\n";
                if ($n_test == 0) {
                    print "  (no test files directly call these functions)\n";
                } else {
                    for my $test (sort keys %func_test_files) {
                        print "  $test\n";
                        if ($verbose) {
                            for my $entry (sort { $a->{line} <=> $b->{line} }
                                           @{$func_test_files{$test}}) {
                                print "    :$entry->{line} calls $entry->{func}\n";
                                print "      $entry->{context}\n";
                            }
                        }
                    }
                }

                # Show transitive lib callers if any
                if (%func_lib_callers && $verbose) {
                    print "\n  Transitive lib callers:\n";
                    for my $func (sort keys %func_lib_callers) {
                        for my $c (sort { $a->{file} cmp $b->{file} }
                                   @{$func_lib_callers{$func}}) {
                            my $enc = $c->{enclosing_sub} ? " (in sub $c->{enclosing_sub})" : "";
                            $enc .= " [entry point, not followed]" if $c->{entry_point};
                            print "    $c->{file}:$c->{line}$enc calls $func\n";
                        }
                    }
                }
                print "\n";
            }

            if (@mod) {
                # Deduplicate module-scope descriptions
                my %seen;
                my @unique = grep { !$seen{$_}++ } @mod;
                print "Module-scoped changes detected:\n";
                print "  - $_\n" for @unique;
                print "  -> Function-level narrowing not possible for this portion.\n";
                print "  -> All module-level dependents are potentially affected.\n\n";
            }

            if (!@funcs && !@mod) {
                print "Only inert changes detected (comments, POD, whitespace).\n";
                print "No functional impact expected.\n\n";
            }
        }

        print "-" x 60, "\n";
        print "CONSERVATIVE BLAST RADIUS — module-level dependents\n";
        print "(listed for completeness; may include false positives when\n";
        print " function-level VR-CONFIRMED TARGETS are shown above)\n";
        print "-" x 60, "\n\n";
    }

    # --- Module-level tier (always shown) ---
    if (@$transitive) {
        print "Transitive lib dependents (" . scalar(@$transitive) . "):\n";
        for my $pkg (@$transitive) {
            print "  $lib_files{$pkg}\n";
            if ($verbose && $chains->{$pkg}) {
                print "    chain: ", join(" -> ", @{$chains->{$pkg}}), "\n";
            }
        }
        print "\n";
    }

    my $total = scalar keys %$tests;
    my $section_label = $func_analysis
        ? "Module-level candidates ($total — conservative, use VR-CONFIRMED TARGETS above for VR):"
        : "Affected test files ($total):";
    print "$section_label\n\n";

    if ($total == 0) {
        print "  (none found)\n";
    } else {
        # Group by top-level directory under tests/
        my %by_dir;
        for my $test (sort keys %$tests) {
            my ($dir) = $test =~ m{^tests/([^/]+)/};
            $dir //= 'other';
            push @{$by_dir{$dir}}, $test;
        }

        for my $dir (sort keys %by_dir) {
            my @files = @{$by_dir{$dir}};
            print "  $dir/ (" . scalar(@files) . " files)\n";
            for my $test (sort @files) {
                print "    $test\n";
                if ($verbose) {
                    for my $pkg (sort @{$tests->{$test}}) {
                        if ($is_target{$pkg}) {
                            print "      via: $pkg (direct)\n";
                        } else {
                            print "      via: ", join(" -> ", @{$chains->{$pkg}}), "\n";
                        }
                    }
                }
            }
        }
    }

    print "\nTotal: $total test files affected (module-level)";
    print " (via " . (scalar(@$targets) + scalar(@$transitive)) . " packages)"
        if @$transitive;
    print "\n";
}

sub print_json {
    my ($targets, $transitive, $tests, $chains, $func_analysis) = @_;

    my %out = (
        targets         => $targets,
        transitive_deps => [],
        affected_tests  => [],
        total           => scalar(keys %$tests),
    );

    for my $pkg (@$transitive) {
        push @{$out{transitive_deps}}, {
            package => $pkg,
            file    => $lib_files{$pkg},
            chain   => $chains->{$pkg} // [],
        };
    }

    for my $test (sort keys %$tests) {
        push @{$out{affected_tests}}, {
            file => $test,
            via  => [sort @{$tests->{$test}}],
        };
    }

    if ($func_analysis) {
        my %fa_out;
        my %func_confirmed_tests;    # test_file => 1 (union of all function callers)
        for my $file (sort keys %$func_analysis) {
            my $fa = $func_analysis->{$file};
            my %file_data = (
                changed_functions => $fa->{changed_functions},
                module_scope      => $fa->{module_scope},
                inert             => $fa->{inert} ? JSON::PP::true : JSON::PP::false,
            );

            if ($fa->{callers}) {
                my %callers_out;
                for my $func (sort keys %{$fa->{callers}}) {
                    $callers_out{$func} = [
                        map { {
                            file    => $_->{file},
                            line    => $_->{line},
                            context => $_->{context},
                            ($_->{enclosing_sub} ? (enclosing_sub => $_->{enclosing_sub}) : ()),
                            ($_->{entry_point} ? (entry_point => JSON::PP::true) : ()),
                        } } @{$fa->{callers}{$func}}
                    ];
                    # Collect test-level callers for recommended_tests
                    for my $c (@{$fa->{callers}{$func}}) {
                        $func_confirmed_tests{$c->{file}} = 1
                            if $c->{file} =~ m{^tests/};
                    }
                }
                $file_data{callers} = \%callers_out;
            }

            $fa_out{$file} = \%file_data;
        }
        $out{function_analysis} = \%fa_out;

        # recommended_tests: function-confirmed tests when available,
        # otherwise fall back to all module-level affected tests.
        # Consumers (classify_changes.pl, gemini) should always use
        # recommended_tests for schedule lookups.
        if (%func_confirmed_tests) {
            $out{recommended_tests} = [sort keys %func_confirmed_tests];
        } else {
            # No function-level callers found (module-scope change or inert):
            # fall back to full module-level list
            $out{recommended_tests} = [map { $_->{file} } @{$out{affected_tests}}];
        }
    } else {
        # No --base: use full module-level list
        $out{recommended_tests} = [map { $_->{file} } @{$out{affected_tests}}];
    }

    print JSON::PP->new->pretty->canonical->encode(\%out);
}

sub log_verbose {
    my ($msg) = @_;
    print STDERR "[INFO] $msg\n" if $verbose;
}

sub print_usage {
    print <<'EOF';
find_affected_tests.pl — Find test files affected by changes to lib/ modules.

USAGE
    perl find_affected_tests.pl [OPTIONS] lib/A/B.pm [lib/C/D.pm ...]

DESCRIPTION
    Given one or more lib/*.pm paths, scans the OSADO codebase to find all
    test files (tests/*.pm) that directly or transitively depend on the changed
    modules.

    Algorithm:
      1. Convert each lib/*.pm path to a Perl package name (lib/A/B.pm → A::B)
      2. Build a reverse dependency map by scanning all use/require in lib/ and tests/
      3. Walk transitive lib-to-lib dependents (BFS with cycle detection)
      4. Collect all tests/*.pm that import any package in the expanded set
      5. Print grouped by directory, with optional dependency chain output

    Five import syntaxes are recognized:
      use Mojo::Base 'Pkg::Name';        — inheritance (single parent)
      use Mojo::Base qw(Pkg1 Pkg2);      — inheritance (multiple parents)
      use Pkg::Name;                      — bare import
      use Pkg::Name qw(...);             — function import list
      require Pkg::Name;                 — runtime require

OPTIONS
    --repo DIR
        Path to the OSADO repository root. Defaults to the current directory.
        The directory must contain lib/ and tests/ subdirectories.

    --base REF
        Enable function-level analysis of the changes committed on the current
        branch since REF (git diff REF...HEAD): identifies which functions
        changed and traces their callers (package-scoped name matching; the
        walk stops at run/post_fail_hook/new/load_* entry points). REF is
        usually the upstream master
        (e.g. upstream/master), as reported by classify_changes.pl. Without
        positional arguments, the changed lib/*.pm files are derived from the
        same range. Uncommitted changes are ignored.

    --verbose
        Show dependency chains and function-level caller details.

    --json
        Output results as JSON instead of human-readable text.

    --help, -h
        Show this help message and exit.

EXAMPLES
    perl find_affected_tests.pl lib/sles4sap/ipaddr2.pm

    perl find_affected_tests.pl --repo /path/to/osado \
        lib/publiccloud/utils.pm lib/utils.pm

    perl find_affected_tests.pl --verbose --repo /path/to/osado lib/LTP/utils.pm

    perl find_affected_tests.pl --json --repo /path/to/osado lib/sles4sap/ipaddr2.pm

    # With function-level analysis of the commits on the current branch:
    perl find_affected_tests.pl --repo /path/to/osado --base upstream/master \
        lib/sles4sap/ipaddr2.pm

SEE ALSO
    classify_changes.pl, find_unit_test.pl, find_test_schedule.pl
EOF
    return 1;
}
