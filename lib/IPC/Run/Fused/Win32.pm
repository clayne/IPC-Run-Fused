use 5.008003;
use strict;
use warnings;

package IPC::Run::Fused::Win32;

our $VERSION = '1.000000';

# ABSTRACT: Implementation of IPC::Run::Fused for Win32

# AUTHORITY

use IO::Handle;
use Module::Runtime;

=method run_fused

  run_fused( $fh, $executable, @params ) || die "$@";
  run_fused( $fh, \$command_string )     || die "$@";
  run_fused( $fh, sub { .. } )           || die "$@";

  # Recommended

  run_fused( my $fh, $executable, @params ) || die "$@";

  # Somewhat supported

  run_fused( my $fh, \$command_string ) || die "$@";

$fh will be clobbered like 'open' does, and $cmd, @args will be passed, as-is, through to exec() or system().

$fh will point to an IO::Handle attached to the end of a pipe running back to the called application.

the command will be run in a fork, and stderr and stdout "fused" into a singluar pipe.

B<NOTE:> at present, STDIN's FD is left unchanged, and child processes will inherit parent STDIN's, and will thus block ( somewhere ) waiting for response.

=cut

sub _fail { goto \&IPC::Run::Fused::_fail }

BEGIN {

  Module::Runtime::require_module('Socket');

  Socket->import();

}

sub run_fused {
  my ( $read_handle, @params ) = @_;
  if ( ref $params[0] and 'CODE' eq ref $params[0] ) {
    goto \&_run_fused_coderef;
  }
  goto \&_run_fused_job;
}

sub _run_fused_job {    ## no critic (Subroutines::RequireArgUnpacking)
  my ( $read_handle, @params ) = @_;

  my $config = _run_fused_jobdecode(@params);

  Module::Runtime::require_module('File::Which');

  $config->{which} = File::Which::which( $config->{executable} );

  local $IPC::Run::Fused::FAIL_CONTEXT{which}      = $config->{which};
  local $IPC::Run::Fused::FAIL_CONTEXT{executable} = $config->{executable};
  local $IPC::Run::Fused::FAIL_CONTEXT{command}    = $config->{command};

  if ( not $config->{which} ) {
    _fail('Failed to resolve executable to path');
  }

  Module::Runtime::require_module('Win32::Job');

  pipe $_[0], my $writer;

  if ( my $pid = fork ) {
    return $pid;
  }

  my $job = Win32::Job->new();
  $job->spawn(
    $config->{which},
    $config->{command},
    {
      stdout => $writer,
      stderr => $writer,
    },
  ) or _fail('Could not spawn job');
  my $result = $job->run( -1, 0 );
  if ( not $result ) {
    my $status = $job->status();
    if ( exists $status->{exitcode} and 293 == $status->{exitcode} ) {
      _fail('Process used more than allotted time');
    }
    _fail( 'Child process terminated with exit code' . $status->{exitcode} );
  }
  exit;
}

sub _run_fused_jobdecode {
  my (@params) = @_;

  if ( ref $params[0] and 'SCALAR' eq ref $params[0] ) {
    my $command = ${ $params[0] };
    $command =~ s/^\s*//;
    return {
      command    => $command,
      executable => _win32_command_find_invocant($command),
    };
  }
  return {
    executable => $params[0],
    command    => _win32_escape_command(@params),
  };
}

sub _run_fused_coderef {    ## no critic (Subroutines::RequireArgUnpacking)

  my ( $read_handle, $code ) = @_;
  my ( $reader, $writer );

  socketpair $reader, $writer, Socket::AF_UNIX, Socket::SOCK_STREAM, Socket::PF_UNSPEC or _fail("creating socketpair");
  shutdown $reader, 1 or _fail("Cant close write to reader");
  shutdown $writer, 0 or _fail("Cant close read to writer");

  if ( my $pid = fork ) {
    $_[0] = $reader;
    return $pid;
  }

  close *STDERR or _fail('Closing STDERR');
  close *STDOUT or _fail('Closing STDOUT');
  open *STDOUT, '>>&=', $writer or _fail('Assigning to STDOUT');
  open *STDERR, '>>&=', $writer or _fail('Assigning to STDERR');
  $code->();
  exit;

}

our $BACKSLASH         = chr 92;
our $DBLBACKSLASH      = $BACKSLASH x 2;
our $DOS_SPECIAL_CHARS = {
  chr 92 => [ 'backslash ',    $BACKSLASH x 2 ],
  chr 34 => [ 'double-quotes', $BACKSLASH . chr 34 ],

  #chr(60) => ['open angle bracket', $backslash . chr(60)],
  #chr(62) => ['close angle bracket', $backslash . chr(62)],
};
our $DOS_REV_CHARS = {
  map { ( $DOS_SPECIAL_CHARS->{$_}->[1], [ $DOS_SPECIAL_CHARS->{$_}->[0], $_ ] ) }
    keys %{$DOS_SPECIAL_CHARS},
};

sub _win32_escape_command_char {
  my ($char) = @_;
  return $char unless exists $DOS_SPECIAL_CHARS->{$char};
  return $DOS_SPECIAL_CHARS->{$char}->[1];
}

sub _win32_escape_command_token {
  my $chars = join q{}, map { _win32_escape_command_char($_) } split //, shift;
  return qq{"$chars"};
}

sub _win32_escape_command {
  my (@tokens) = @_;
  return join q{ }, map { _win32_escape_command_token($_) } @tokens;
}

sub _win32_command_find_invocant {
  my ($command) = @_;
  $command = "$command";
  my $first = q[];
  my @chars = split //, $command;
  my $inquote;

  while (@chars) {
    my $char  = $chars[0];
    my $dchar = $chars[0] . $chars[1];

    if ( not $inquote and q["] eq $char ) {
      $inquote = 1;
      shift @chars;
      next;
    }
    if ( $inquote and q["] eq $char ) {
      $inquote = undef;
      shift @chars;
      next;
    }
    if ( exists $DOS_REV_CHARS->{$dchar} ) {
      $first .= $DOS_REV_CHARS->{$dchar}->[1];
      shift @chars;
      shift @chars;
      next;
    }
    if ( q[ ] eq $char and not $inquote ) {
      if ( not length $first ) {
        shift @chars;
        next;
      }
      return $first;
    }
    if ( q[ ] eq $char and $inquote ) {
      $first .= $char;
      shift @chars;
      next;
    }
    $first .= $char;
    shift @chars;
  }
  if ($inquote) {
    _fail('Could not parse command from commandline');
  }
  return $first;
}

1;
