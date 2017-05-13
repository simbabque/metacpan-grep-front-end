package grepcpan;

use Dancer2;
use Dancer2::Serializer::JSON;

our $VERSION = '0.1';

my $GrepCpanConfig = config()->{'grepcpan'};
my $grep = GrepCpan->new( config => $GrepCpanConfig );

my $COOKIE_LAST_SEARCH = $GrepCpanConfig->{'cookie'}->{'history_name'}
  or die "missing cookie:history entry";

###
### regular routes
###

get '/' => \&home;

get '/about' => sub {
    return template 'about' =>
      { 'title' => 'About grep::metacpan', menu => 'about' };
};

get '/faq' => sub {
    return template 'faq' =>
      { 'title' => 'FAQs for grep::metacpan', menu => 'faq' };
};

get '/api' => sub {
    return template 'api' =>
      { 'title' => 'APIs how to use grep::metacpan APIs', menu => 'api' };
};

get '/source-code' => sub {
    return template 'source-code' => {
        'title' => 'Source code of grep::metacpan, list of git reposities',
        menu    => 'gh'
    };
};

get '/search' => sub {

    my $q        = param('q');          # FIXME clean query
    my $filetype = param('qft');
    my $qdistro  = param('qd');
    my $qci      = param('qci'); # case insensitive
    my $page     = param('p') || 1;
    my $query    = $grep->do_search(
        search   => $q,
        page     => $page - 1,
        filetype => $filetype,
        caseinsensitive => $qci,
		query_distro  => $qdistro, # custom search with glob
    );

    return template 'search' => {
        search        => $q,
        query         => $query,
        page          => $page,
        last_searches => _update_history_cookie($q),
        show_sumup    => 1,
        qft           => $filetype // q{},
        qd            => $qdistro // q{},
        qci           => $qci,
    };
};

get '/search/:distro/' => sub {
    my $q        = param('q');          # FIXME clean query
    my $filetype = param('qft');
    my $qdistro  = param('qd');
    my $qci      = param('qci'); # case insensitive
    my $page     = param('p') || 1;
    my $distro   = param('distro');
    my $file     = param('f');
    my $query    = $grep->do_search(
        search        => $q,
        page          => $page - 1,
        search_distro => $distro, # filter on a distribution
        query_distro  => $qdistro, # custom search with glob
        search_file   => $file,
        filetype      => $filetype,
        caseinsensitive => $qci,        
    );

    my $nopagination = defined $file   && length $file   ? 1 : 0;
    my $show_sumup   = defined $distro && length $distro ? 0 : 1;

    return template 'search' => {
        search        => $q,
        search_distro => $distro,
        query         => $query,
        page          => $page,
        last_searches => _update_history_cookie($q),
        nopagination  => $nopagination,
        show_sumup    => $show_sumup,
        qt            => $filetype // q{},
        qd            => $distro, #$qdistro // q{},
        qci           => $qci,
    };
};

### API routes
get '/api/search' => sub {

    my $q        = param('q');          # FIXME clean query
    my $page     = param('p') || 1;
    my $filetype = param('filetype');
    my $query    = $grep->do_search(
        search   => $q,
        page     => $page - 1,
        filetype => $filetype
    );

    content_type 'application/json';
    return to_json $query;
};

get '/api/search/:distro/' => sub {
    my $q        = param('q');          # FIXME clean query
    my $page     = param('p') || 1;
    my $distro   = param('distro');
    my $file     = param('f');
    my $filetype = param('filetype');
    my $query    = $grep->do_search(
        search        => $q,
        page          => $page - 1,
        search_distro => $distro,
        search_file   => $file,
        filetype      => $filetype
    );

    content_type 'application/json';
    return to_json $query;
};

###
### dummies helpers
###

sub _update_history_cookie { # and return the human version list in all cases...
    my $search = shift;

    my $separator = q{||};

    my $value = cookie($COOKIE_LAST_SEARCH);

    my @last_searches = split( qr{\Q$separator\E}, $value // '' );

    if ( defined $search && length $search ) {
        $value =~ s{\Q$separator\E}{.}g;    # mmmm
        @last_searches = grep { $_ ne $search }
          @last_searches;                   # remove it from history if there
        unshift @last_searches, $search;    # move it first
        @last_searches = splice( @last_searches, 0,
            $GrepCpanConfig->{'cookie'}->{'history_size'} );
        cookie $COOKIE_LAST_SEARCH => join( $separator, @last_searches ),
          expires                  => "21 days";
    }

    return \@last_searches;
}

sub tt {
    my ( $template, $params ) = @_;

    if ( ref $params ) {

        #$params->{is_mobile} = 1 if is_mobile_device();
    }

    return template( $template, $params );
}

sub home {
    template( 'index' => { 'title' => 'grepcpan' } );
}

true;

package GrepCpan;

use strict;
use warnings;

use Git::Repository ();

=pod

git grep -l to a file to cache the result ( limit it to 200 files and run it in background after ?? )
use this list for pagination
then do a query for a set of files with context

grepcpan@grep.cpan.me [~/minicpan_grep.git]# time git grep -C15 -n xyz HEAD | head -n 200

=cut

use Simple::Accessor
  qw{ config git cache distros_per_page search_context search_context_file search_context_distro git_binary };
use POSIX qw{:sys_wait_h setsid};
use Proc::ProcessTable ();
use YAML::Syck         ();
use Time::HiRes        ();
use File::Slurp        ();
use IO::Handle         ();
use Test::More;

use Digest::MD5 qw( md5_hex );

use constant END_OF_FILE_MARKER => qq{##______END_OF_FILE_MARKER______##};

use v5.024;

$YAML::Syck::LoadBlessed = 0;
$YAML::Syck::SortKeys    = 1;

sub _build_git {
    my $self = shift;

    my $gitdir = $self->config()->{'gitrepo'};
    die qq{Invalid git directory $gitdir} unless defined $gitdir && -d $gitdir;

    return Git::Repository->new(
        work_tree => $gitdir,
        { git => $self->git_binary }
    );
}

sub _build_git_binary {
    my $self = shift;

    my $git = $self->config()->{'binaries'}->{'git'};
    return $git if $git && -x $git;
    $git = qx{which git};
    chomp $git;

    return $git;
}

sub _build_cache {
    my $self = shift;

    # also use HEAD ?? FIXME
    my $dir = $self->config()->{'cache'}->{'directory'} . '/'
      . ( $self->config()->{'cache'}->{'version'} || 0 );
    die unless $dir;
    qx{mkdir -p $dir};    # cleanup
    die unless -d $dir;
    return $dir;
}

## TODO factorize
sub _build_distros_per_page {
    my $self = shift;
    my $v    = $self->config()->{limit}{'distros_per_page'};
    $v or die;
    return int($v);
}

sub _build_search_context {
    my $self = shift;
    my $v    = $self->config()->{limit}{'search_context'};
    $v or die;
    return int($v);
}

sub _build_search_context_distro {
    my $self = shift;
    my $v    = $self->config()->{limit}{'search_context_distro'};
    $v or die;
    return int($v);
}

sub _build_search_context_file {
    my $self = shift;
    my $v    = $self->config()->{limit}{'search_context_file'};
    $v or die;
    return int($v);
}

sub _sanitize_search {
    my $s = shift;
    return undef unless defined $s;
    $s =~ s{\n}{}g;
    $s =~ s{'}{\'}g;

    $s =~ s{[^a-zA-Z0-9\-\.\?\\*\&_'"~!$%^()\[\]\{\}:;<>,/@| ]}{}g
      ;    # whitelist possible characters ?

    return $s;
}

sub _get_git_grep_flavor {
    my $s = shift;

    # regular characters
    return q{--fixed-string} if $s =~ qr{^[a-zA-Z0-9&_'"~:;<>,/| ]+$};
    return q{-P};
}

# idea use git rev-parse HEAD to include it in the cache name

sub do_search {
    my ( $self, %opts ) = @_;

    my ( $search, $page, $search_distro, $search_file, 
    	$filetype, $caseinsensitive, $query_distro,
     ) = (
        $opts{search}, $opts{page}, $opts{search_distro}, $opts{search_file},
        $opts{filetype}, $opts{caseinsensitive}, $opts{query_distro},
    );

    my $t0 = [Time::HiRes::gettimeofday];

    my $gitdir = $self->git()->work_tree;

    $search = _sanitize_search($search);

    $page //= 0;
    $page = 0 if $page < 0;
    my $cache = $self->get_match_cache( $search, $search_distro // $query_distro, $filetype, $caseinsensitive );

    my $context = $self->search_context();    # default context
    if ( defined $search_file ) {
        $context = $self->search_context_file();
    }
    elsif ( defined $search_distro ) {
        $context = $self->search_context_distro();
    }

    my $files_to_search =
      $self->get_list_of_files_to_search( $cache, $search, $page,
        $search_distro, $search_file, $filetype );

    # can also probably simply use Git::Repo there
    my $matches;

    if ( scalar @$files_to_search ) {
        my $flavor = _get_git_grep_flavor($search);
        my @git_cmd = ( 'grep' );
        push @git_cmd, '-i' if $caseinsensitive;
        push @git_cmd, (
            '-n',    '--heading', '-C',
            $context, $flavor, $search,     '--',
            $files_to_search->@*
        );
        my @out    = $self->git->run( @git_cmd );
        $matches = \@out;
    }

    # now format the output in order to be able to use it
    my @output;
    my $current_file;
    my @diffblocks;
    my $diff = '';
    my $line_number;
    my $start_line;
    my @matching_lines;

    my $add_block = sub {
        return unless $diff && length($diff);
        push @diffblocks,
          {
            code       => $diff,
            start_at   => $start_line || 1,
            matchlines => [@matching_lines]
          };
        return;
    };

    my $process_file = sub {
        return unless defined $current_file;
        $add_block->();    # push the last block

        my ( $where, $distro, $shortpath ) = massage_filepath($current_file);
        return unless length $shortpath;
        my $prefix = join '/', $where, $distro;

        my $result = $cache->{distros}->{$distro} // {};
        $result->{distro}  //= $distro;
        $result->{matches} //= [];

        #@diffblocks = scalar @diffblocks; # debugging clear the blocks
        push $result->{matches}->@*,
          { file => $shortpath, blocks => [@diffblocks] };
        return
          if scalar @output
          && $output[-1] eq $result;    # same hash do not add it more than once
        push @output, $result;

        return;
    };

    foreach my $line (@$matches) {
        if ( !defined $current_file && $line !~ qr{^([0-9]+)[-:]} )
        { # when more than one block match we are just going to have a -- separator
            $current_file = $line;
        }
        elsif ( $line eq '--' ) {
            $process_file->();
            undef $current_file;
            $diff       = '';
            @diffblocks = ();
            undef $start_line;
            undef $line_number;
            @matching_lines = ();
        }
        elsif ( $line =~ s{^([0-9]+)([-:])}{} ) {    # mainly else
            my $new_line = $1;
            my $prefix   = $2;
            $start_line //= $new_line;
            if ( length($line) > 250 )
            {    # max length autorized ( js minified & co )
                $line = substr( $line, 0, 250 ) . '...';
            }
            if ( !defined $line_number || $new_line == $line_number + 1 ) {

                # same block
                push @matching_lines, $new_line if $prefix eq ':';
                $diff .= $line . "\n";
            }
            else {
                # new block
                $add_block->();
                $diff = $line . "\n";    # reset the block
            }
            $line_number = $new_line;
        }
    }
    $process_file->();                   # process the last block

    my $elapsed = Time::HiRes::tv_interval( $t0, [Time::HiRes::gettimeofday] );

    return {
        is_incomplete      => $cache->{is_incomplete}      || 0,
        search_in_progress => $cache->{search_in_progress} || 0,
        match              => $cache->{match},
        results            => \@output,
        time_elapsed       => $elapsed,
    };
}

sub get_list_of_files_to_search {
    my ( $self, $cache, $search, $page, $search_distro, $search_file,
        $filetype ) = @_;

# try to get one file per distro except if we do not have enough distros matching
# maybe sort the files by distros having the most matches ??

    my @flat_list;    # full flat list before pagination

    # if we have enough distros
    my $limit = $self->distros_per_page;
    if ( defined $search_distro ) {

        # let's pick all the files for this distro
        my $distro = $search_distro;
        return [] unless exists $cache->{distros}->{$distro};
        my $prefix = $cache->{distros}->{$distro}->{prefix};
        @flat_list = map { $prefix . '/' . $_ }
          $cache->{distros}->{$distro}->{files}->@*;    # all the files
        if ( defined $search_file ) {
            @flat_list = grep { $_ eq $prefix . '/' . $search_file }
              @flat_list;    # make sure the file is known and sanitize
        }

        #} elsif ( scalar keys $cache->{distros}->%* > $limit ) {
    }
    else {                   # pick one single file per distro
                             #my @distros =
        @flat_list = map {
            my $distro        = $_;
            my $prefix        = $cache->{distros}->{$distro}->{prefix};
            my $list_of_files = $cache->{distros}->{$distro}->{files};
            my $candidate = $list_of_files->[0];    # only the first file
            if ( scalar $list_of_files->@* > 1 ) {

                # try to find a more perlish file first
                foreach my $f ( $list_of_files->@* ) {
                    if ( $f =~ qr{\.p[lm]$} ) {
                        $candidate = $f;
                        last;
                    }
                }
            }

            # use our best candidate ( and add our prefix )
            $prefix . '/' . $candidate;
          }
          sort keys $cache->{distros}->%*;
    }

    # now do the pagination
    # page 0: from 0 to limit - 1
    # page 1: from limit to 2 * limit - 1
    # page 2: from 2*limit to 3 * limit - 1

    my @short = splice( @flat_list, $page * $limit, $limit );

    return \@short;
}

sub get_match_cache {
    my ( $self, $search, $search_distro, $query_filetype, $caseinsensitive ) = @_;

    $caseinsensitive //= 0;

    my $gitdir = $self->git()->work_tree;
    my $limit = $self->config()->{limit}->{files_per_search} or die;

    my $flavor = _get_git_grep_flavor($search);
    my @git_cmd = qw{grep -l};
    push @git_cmd, q{-i} if $caseinsensitive;
    push @git_cmd, $flavor, $search, q{--}, q{distros/};

    # use the full cache when available -- need to filter it later
    my $cache_file = $self->cache() . '/search-ls-' . md5_hex($search . q{|} . $caseinsensitive ) . '.cache';
	return YAML::Syck::LoadFile($cache_file) if -e $cache_file && !$self->config()->{nocache};

	$search_distro =~ s{::+}{-}g if defined $search_distro;
	# the distro can either come from url or the query with some glob
    if ( defined $search_distro && length($search_distro) && $search_distro =~ qr{^([0-9a-zA-Z_\*])[0-9a-zA-Z_\*\-]*$} ) {
    	# replace the disros search
    	$git_cmd[-1] = q{distros/} . $1 . '/' . $search_distro . '/*'; # add a / to do not match some other distro
    }

	# filter on some type files distro + query filetype
    if (   defined $query_filetype && length $query_filetype && $query_filetype =~ qr{^[0-9\.\-\*_a-zA-Z]+$} ) {
        # append to the distros search
        $git_cmd[-1] .= '*' . $query_filetype;
    }

    # fallback to a shorter search ( and a different cache )
    $cache_file = $self->cache() . '/search-ls-' . md5_hex( join( '|', @git_cmd ) ) . '.cache';
    return YAML::Syck::LoadFile($cache_file)
      if -e $cache_file
      && !$self->config()->{nocache};    # maybe also check the timestamp FIXME

    my $raw_cache_file = $cache_file . q{.raw};

    my $raw_limit = $self->config()->{limit}->{files_git_run_bg};

    my $list_files = $self->run_git_cmd_limit(
        cache_file       => $raw_cache_file,
        cmd              => [@git_cmd],       # git command
        limit            => $limit,
        limit_bg_process => $raw_limit,       #files_git_run_bg
                                              #pre_run => sub { chdir($gitdir) }
    );

    # remove the final marker if there
    my $search_in_progress = 1;
    #note "LAST LINE .... " . $list_files->[-1];
    #note " check  ? ", $list_files->[-1] eq END_OF_FILE_MARKER() ? 1 : 0;
    if ( scalar @$list_files && $list_files->[-1] eq END_OF_FILE_MARKER() ) {
        pop @$list_files;
        $search_in_progress = 0;
    }

    my $cache = {
        distros            => {},
        search             => $search,
        search_in_progress => $search_in_progress
    };
    my $match_files = scalar @$list_files;
    $cache->{is_incomplete} = 1 if $match_files >= $raw_limit;

    my $last_distro;
    foreach my $line (@$list_files) {
        my ( $where, $distro, $shortpath ) = massage_filepath($line);
        next unless defined $shortpath;
        $last_distro = $distro;
        my $prefix = join '/', $where, $distro;
        $cache->{distros}->{$distro} //= { files => [], prefix => $prefix };
        push $cache->{distros}->{$distro}->{files}->@*, $shortpath;
    }

    if ( $cache->{is_incomplete} )
    {    # flag the last distro as potentially incomplete
        $cache->{distros}->{$last_distro}->{'is_incomplete'} = 1;
    }

    $cache->{match} =
      { files => $match_files, distros => scalar keys $cache->{distros}->%* };

    #note explain $cache;
    if ( !$search_in_progress ) {
        #note "Search in progress..... done caching yaml file";
        YAML::Syck::DumpFile( $cache_file, $cache );
        unlink($raw_cache_file) if -e $raw_cache_file;
    }

    return $cache;
}

sub massage_filepath {
    my $line = shift;
    my ( $where, $letter, $distro, $shortpath ) = split( q{/}, $line, 4 );
    $where  //= '';
    $letter //= '';
    $where .= '/' . $letter;
    return ( $where, $distro, $shortpath );
}

sub run_git_cmd_limit {
    my ( $self, %opts ) = @_;

    my $cache_file = $opts{cache_file};
    my $cmd = $opts{cmd} // die;
    ref $cmd eq 'ARRAY' or die "cmd should be an ARRAY ref";
    my $limit            = $opts{limit}            || 10;
    my $limit_bg_process = $opts{limit_bg_process} || $limit;

    my @lines;

    if ( $cache_file && -e $cache_file && !$self->config()->{nocache} ) {

        # check if the file is empty and has more than X seconds

        while ( waitpid( -1, WNOHANG ) > 0 ) { 1 }; # catch any zombies we could have from previous run

        if ( -z $cache_file ) {                     # the file is empty
            my ( $mtime, $ctime ) = ( stat($cache_file) )[ 9, 10 ];
            $mtime //= 0;
            $ctime //= 0;

            # return an empty cache if the file exists and is empty...
            return [] if ( time() - $mtime < 60 * 30 );

            # give it a second try after some time...
        }
        else {
            # return the content of our current cache from previous run
            #note "use our cache from previous run";
            my @from_cache = File::Slurp::read_file($cache_file);
            chomp @from_cache;
            return \@from_cache;
        }
    }

    local $| = 1;
    local $SIG{'USR1'} = sub { exit }; # avoid a race condition and exit cleanly

    #my $child_pid = open( my $from_kid, "-|" ) // die "Can't fork: $!";

    local $SIG{'CHLD'} = 'DEFAULT';

    my ( $from_kid, $CW ) = ( IO::Handle->new(), IO::Handle->new() );
    pipe( $from_kid, $CW ) or die "Fail to pipe $!";
    $CW->autoflush(1);

    my $child_pid = fork();
    die "Fork failed" unless defined $child_pid;

    local $SIG{'ALRM'} = sub { die "Alarm signal triggered - $$" };

    if ($child_pid) {    # parent process
        my $c = 1;
        alarm( $self->config->{timeout}->{user_search} );
        eval {
            while ( my $line = readline($from_kid) ) {
                chomp $line;
                push @lines, $line;
                last if ++$c > $limit;
                #note "GOT: $line ", $line eq END_OF_FILE_MARKER() ? 1 : 0;
                last if $line eq END_OF_FILE_MARKER();
            }
            alarm(0);
            1;
        };# or warn $@;
        close($from_kid);
        kill 'USR1' => $child_pid;
        while ( waitpid( -1, WNOHANG ) > 0 ) { 1 }; # catch what we can at this step... the process is running in bg
    }
    else {
        # in kid process
        local $| = 1;
        my $current_pid       = $$;
        my $can_write_to_pipe = 1;
        local $SIG{'USR1'} = sub {                  # not really used anymore
            #warn "SIGUSR1.... start";
            $can_write_to_pipe = 0;
            close($CW);
            open STDIN,  '>', '/dev/null';
            open STDOUT, '>', '/dev/null';
            open STDERR, '>', '/dev/null';
            setsid();

            return;
        };
        local $SIG{'ALRM'} = sub { die };           # probably not required
        alarm( $self->config->{timeout}->{grep_search} )
          ;    # limit our search in time...
        $opts{pre_run}->() if ref $opts{pre_run} eq 'CODE';

        note "Running in kid command: " . join( ' ', @$cmd );
        note "KID is caching to file ", $cache_file;

        my $to_cache;

        if ($cache_file) {
            $to_cache = IO::Handle->new;
            open( $to_cache, q{>}, $cache_file )
              or die "Cannot open cache file: $!";
            $to_cache->autoflush(1);
        }

        my $run     = $self->git->command(@$cmd);
        my $log     = $run->stdout;
        my $counter = 1;

        while ( readline $log ) {
            print {$CW} $_
              if $can_write_to_pipe;    # return the line to our parent
            if ($cache_file) {
                print {$to_cache} $_ or die;    # if file is removed
            }
            last if ++$counter > $limit_bg_process;
        }
        $run->close;
        print {$to_cache}
          qq{\n};    # in case of the last line did not had a newline
        print {$to_cache} END_OF_FILE_MARKER() . qq{\n} if $cache_file;
        print {$CW} END_OF_FILE_MARKER() . qq{\n}       if $can_write_to_pipe;
        note "-- Request finished by kid: $counter lines - "
          . join( ' ', @$cmd );
        exit $?;
    }

    return \@lines;
}

1;