package PVE::Daemon;

# Abstract class to implement Daemons
#
# Features:
# * lock and write PID file /var/run/$name.pid to make sure onyl
#   one instance is running.
# * keep lock open during restart
# * correctly daemonize (redirect STDIN/STDOUT)
# * restart by stop/start, exec, or signal HUP
# * daemon restart on error (option 'restart_on_error')
# * handle worker processes (option 'max_workers')
# * allow to restart while workers are still runningl
#   (option 'leave_children_open_on_reload')
 
use strict;
use warnings;
use PVE::SafeSyslog;
use PVE::INotify;

use POSIX ":sys_wait_h";
use Fcntl ':flock';
use Socket qw(IPPROTO_TCP TCP_NODELAY SOMAXCONN);
use IO::Socket::INET;

use Getopt::Long;
use Time::HiRes qw (gettimeofday);

use base qw(PVE::CLIHandler);

$ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

my $daemon_initialized = 0; # we only allow one instance

my $close_daemon_lock = sub {
    my ($self) = @_;

    return if !$self->{daemon_lock_fh};

    close $self->{daemon_lock_fh};
    delete $self->{daemon_lock_fh};
};

my $log_err = sub {
    my ($msg) = @_;
    chomp $msg;
    print STDERR "$msg\n";
    syslog('err', "%s", $msg);
};

# call this if you fork() from child
# Note: we already call this for workers, so it is only required
# if you fork inside a simple daemon (max_workers == 0).
sub after_fork_cleanup {
    my ($self) = @_;

    &$close_daemon_lock($self);

    PVE::INotify::inotify_close();

    for my $sig (qw(CHLD HUP INT TERM QUIT)) {
	$SIG{$sig} = 'DEFAULT'; # restore default handler
	# AnyEvent signals only works if $SIG{XX} is 
	# undefined (perl event loop)
	delete $SIG{$sig}; # so that we can handle events with AnyEvent
    }
}

my $lockpidfile = sub {
    my ($self) = @_;

    my $lkfn = $self->{pidfile} . ".lock";

    my $waittime = 0;

    if (my $fd = $self->{env_pve_lock_fd}) {

	$self->{daemon_lock_fh} = IO::Handle->new_from_fd($fd, "a");
	
    } else {

	$waittime = 5;
	$self->{daemon_lock_fh} = IO::File->new(">>$lkfn");
    }

    if (!$self->{daemon_lock_fh}) {
	die "can't open lock '$lkfn' - $!\n";
    }

    for (my $i = 0; $i < $waittime; $i ++) {
	return if flock ($self->{daemon_lock_fh}, LOCK_EX|LOCK_NB);
	sleep(1);
    }

    if (!flock ($self->{daemon_lock_fh}, LOCK_EX|LOCK_NB)) {
	&$close_daemon_lock($self);
	my $err = $!;

	my ($running, $pid) = $self->running();
	if ($running) {
	    die "can't aquire lock '$lkfn' - daemon already started (pid = $pid)\n";
	} else {
	    die "can't aquire lock '$lkfn' - $err\n";
	}
    }
};

my $writepidfile = sub {
    my ($self) = @_;

    my $pidfile = $self->{pidfile};

    die "can't open pid file '$pidfile' - $!\n" if !open (PIDFH, ">$pidfile");

    print PIDFH "$$\n";
    close (PIDFH);
};

my $server_cleanup = sub {
    my ($self) = @_;

    unlink $self->{pidfile} . ".lock";
    unlink $self->{pidfile};
};

my $finish_workers = sub {
    my ($self) = @_;

    foreach my $id (qw(workers old_workers)) {
	foreach my $cpid (keys %{$self->{$id}}) {
	    my $waitpid = waitpid($cpid, WNOHANG);
	    if (defined($waitpid) && ($waitpid == $cpid)) {
		delete ($self->{$id}->{$cpid});
		syslog('info', "worker $cpid finished");
	    }
	}
    }
};

my $start_workers = sub {
    my ($self) = @_;

    return if $self->{terminate};

    my $count = 0;
    foreach my $cpid (keys %{$self->{workers}}) {
	$count++;
    }

    my $need = $self->{max_workers} - $count;

    return if $need <= 0;

    syslog('info', "starting $need worker(s)");

    while ($need > 0) {
	my $pid = fork;

	if (!defined ($pid)) {
	    syslog('err', "can't fork worker");
	    sleep (1);
	} elsif ($pid) { # parent
	    $self->{workers}->{$pid} = 1;
	    syslog('info', "worker $pid started");
	    $need--;
	} else {
	    $0 = "$self->{name} worker";

	    $self->after_fork_cleanup();

	    eval { $self->run(); };
	    if (my $err = $@) {
		syslog('err', $err);
		sleep(5); # avoid fast restarts
	    }

	    syslog('info', "worker exit");
	    exit (0);
	}
    }
};

my $terminate_server = sub {
    my ($self, $allow_open_children) = @_;

    $self->{terminate} = 1; # set flag to avoid worker restart

    if (!$self->{max_workers}) {
	eval { $self->shutdown(); };
	warn $@ if $@;
	return;
    }

    eval { $self->shutdown(); };
    warn $@ if $@;

    # we have workers - send TERM signal

    foreach my $cpid (keys %{$self->{workers}}) {
	kill(15, $cpid); # TERM childs
    }

    # if configured, leave children running on HUP
    return if $allow_open_children &&
	$self->{leave_children_open_on_reload};

    # else, send TERM to old workers
    foreach my $cpid (keys %{$self->{old_workers}}) {
	kill(15, $cpid); # TERM childs
    }

    # nicely shutdown childs (give them max 10 seconds to shut down)
    my $previous_alarm = alarm(10);
    eval {
	local $SIG{ALRM} = sub { die "timeout\n" };

	while ((my $pid = waitpid (-1, 0)) > 0) {
	    foreach my $id (qw(workers old_workers)) {
		if (defined($self->{$id}->{$pid})) {
		    delete($self->{$id}->{$pid});
		    syslog('info', "worker $pid finished");
		}
	    }
	}
	alarm(0); # avoid race condition
    };
    my $err = $@;

    alarm ($previous_alarm);

    if ($err) {
	syslog('err', "error stopping workers (will kill them now) - $err");
	foreach my $id (qw(workers old_workers)) {
	    foreach my $cpid (keys %{$self->{$id}}) {
		# KILL childs still alive!
		if (kill (0, $cpid)) {
		    delete($self->{$id}->{$cpid});
		    syslog("err", "kill worker $cpid");
		    kill(9, $cpid);
		    # fixme: waitpid?
		}
	    }
	}
    }
};

my $server_run = sub {
    my ($self, $debug) = @_;

    # fixme: handle restart lockfd
    &$lockpidfile($self);

    # remove FD_CLOEXEC bit to reuse on exec
    $self->{daemon_lock_fh}->fcntl(Fcntl::F_SETFD(), 0);

    $ENV{PVE_DAEMON_LOCK_FD} = $self->{daemon_lock_fh}->fileno;

    # run in background
    my $spid;

    $self->{debug} = 1 if $debug;

    $self->init();

    if (!$debug) {
	open STDIN,  '</dev/null' || die "can't read /dev/null";
	open STDOUT, '>/dev/null' || die "can't write /dev/null";
    }

    if (!$self->{env_restart_pve_daemon} && !$debug) {
	PVE::INotify::inotify_close();
	$spid = fork();
	if (!defined ($spid)) {
	    die "can't put server into background - fork failed";
	} elsif ($spid) { # parent
	    exit (0);
	}
	PVE::INotify::inotify_init();
    }

    if ($self->{env_restart_pve_daemon}) {
	syslog('info' , "restarting server");
    } else {
	&$writepidfile($self);
	syslog('info' , "starting server");
    }

    POSIX::setsid(); 

    open STDERR, '>&STDOUT' || die "can't close STDERR\n";

    my $old_sig_term = $SIG{TERM};
    local $SIG{TERM} = sub {
	local ($@, $!, $?); # do not overwrite error vars
	syslog('info', "received signal TERM");
	&$terminate_server($self, 0);
	&$server_cleanup($self);
	&$old_sig_term(@_) if $old_sig_term;
    };

    my $old_sig_quit = $SIG{QUIT};
    local $SIG{QUIT} = sub {
	local ($@, $!, $?); # do not overwrite error vars
	syslog('info', "received signal QUIT");
	&$terminate_server($self, 0);
	&$server_cleanup($self);
	&$old_sig_quit(@_) if $old_sig_quit;
    };

    my $old_sig_int = $SIG{INT};
    local $SIG{INT} = sub {
	local ($@, $!, $?); # do not overwrite error vars
	syslog('info', "received signal INT");
	$SIG{INT} = 'DEFAULT'; # allow to terminate now
	&$terminate_server($self, 0);
	&$server_cleanup($self);
	&$old_sig_int(@_) if $old_sig_int;
    };

    $SIG{HUP} = sub {
	local ($@, $!, $?); # do not overwrite error vars
	syslog('info', "received signal HUP");
	$self->{got_hup_signal} = 1;
	if ($self->{max_workers}) {
	    &$terminate_server($self, 1);
	} elsif ($self->can('hup')) {
	    eval { $self->hup() };
	    warn $@ if $@;
	}
    };

    eval { 
	if ($self->{max_workers}) {
	    my $old_sig_chld = $SIG{CHLD};
	    local $SIG{CHLD} = sub {
		local ($@, $!, $?); # do not overwrite error vars
		&$finish_workers($self);
		&$old_sig_chld(@_) if $old_sig_chld;
	    };

	    # catch worker finished during restart phase 
	    &$finish_workers($self);

	    # now loop forever (until we receive terminate signal)
	    for (;;) { 
		&$start_workers($self);
		sleep(5);
		&$finish_workers($self);
		last if $self->{terminate};
	    }

	} else {
	    $self->run();
	} 
    };
    my $err = $@;

    if ($err) {
	syslog ('err', "ERROR: $err");

	&$terminate_server($self, 1);

	if (my $wait_time = $self->{restart_on_error}) {
	    $self->restart_daemon($wait_time);
	} else {
	    $self->exit_daemon(-1);
	}
    }

    if ($self->{got_hup_signal}) {
	$self->restart_daemon();
    } else {
	$self->exit_daemon(0);
    }
};

sub new {
    my ($this, $name, $cmdline, %params) = @_;

    $name = 'daemon' if !$name; # should not happen

    initlog($name);

    my $self;

    eval {

	my $restart = $ENV{RESTART_PVE_DAEMON};
	delete $ENV{RESTART_PVE_DAEMON};

	my $lockfd = $ENV{PVE_DAEMON_LOCK_FD};
	delete $ENV{PVE_DAEMON_LOCK_FD};

	if (defined($lockfd)) {
	    die "unable to parse lock fd '$lockfd'\n"
		if $lockfd !~ m/^(\d+)$/;
	    $lockfd = $1; # untaint
	}

	die "please run as root\n" if !$restart && ($> != 0);

	die "can't create more that one PVE::Daemon" if $daemon_initialized;
	$daemon_initialized = 1;

	PVE::INotify::inotify_init();

	my $class = ref($this) || $this;

	$self = bless { 
	    name => $name,
	    run_dir => '/var/run',
	    env_restart_pve_daemon => $restart,
	    env_pve_lock_fd => $lockfd,
	    workers => {},
	    old_workers => {},
	}, $class;

	foreach my $opt (keys %params) {
	    my $value = $params{$opt};
	    if ($opt eq 'restart_on_error') {
		$self->{$opt} = $value;
	    } elsif ($opt eq 'stop_wait_time') {
		$self->{$opt} = $value;
	    } elsif ($opt eq 'run_dir') {
		$self->{$opt} = $value;
	    } elsif ($opt eq 'max_workers') {
		$self->{$opt} = $value;
	    } elsif ($opt eq 'leave_children_open_on_reload') {
		$self->{$opt} = $value;
	    } else {
		die "unknown daemon option '$opt'\n";
	    }
	}
	
	if ($restart && $self->{max_workers}) {
	    if (my $wpids = $ENV{PVE_DAEMON_WORKER_PIDS}) {
		foreach my $pid (split(':', $wpids)) {
		    if ($pid =~ m/^(\d+)$/) {
			$self->{old_workers}->{$1} = 1;
		    }
		}
	    }
	}

	$self->{pidfile} = "$self->{run_dir}/${name}.pid";

	$self->{nodename} = PVE::INotify::nodename();

	$self->{cmdline} = [];

	foreach my $el (@$cmdline) {
	    $el =~ m/^(.*)$/; # untaint
	    push @{$self->{cmdline}}, $1;
	}

	$0 = $name;
    };
    if (my $err = $@) {
	&$log_err($err);
	exit(-1);
    }

    return $self;
}

sub exit_daemon {
    my ($self, $status) = @_;

    syslog("info", "server stopped");

    &$server_cleanup($self);

    exit($status);
}

sub restart_daemon {
    my ($self, $waittime) = @_;

    syslog('info', "server shutdown (restart)");

    $ENV{RESTART_PVE_DAEMON} = 1;

    if ($self->{max_workers}) {
	my @workers = keys %{$self->{workers}};
	push @workers, keys %{$self->{old_workers}};
	$ENV{PVE_DAEMON_WORKER_PIDS} = join(':', @workers);
    }

    sleep($waittime) if $waittime; # avoid high server load due to restarts

    PVE::INotify::inotify_close();

    exec (@{$self->{cmdline}});

    exit (-1); # never reached?
}

# please overwrite in subclass
# this is called at startup - before forking
sub init {
    my ($self) = @_;

}

# please overwrite in subclass
sub shutdown {
    my ($self) = @_;

    syslog('info' , "server closing");

    if (!$self->{max_workers}) {
	# wait for children
	1 while (waitpid(-1, POSIX::WNOHANG()) > 0);
    }
}

# please define in subclass
#sub hup {
#    my ($self) = @_;
#
#    syslog('info' , "received signal HUP (restart)");
#}

# please overwrite in subclass
sub run {
    my ($self) = @_;

    for (;;) { # forever
	syslog('info' , "server is running");
	sleep(5);
    }
}

sub start {
    my ($self, $debug) = @_;

    eval  { &$server_run($self, $debug); };
    if (my $err = $@) {
	&$log_err("start failed - $err");
	exit(-1);
    }
}

my $read_pid = sub {
    my ($self) = @_;

    my $pid_str = PVE::Tools::file_read_firstline($self->{pidfile});

    return 0 if !$pid_str;

    return 0 if $pid_str !~ m/^(\d+)$/; # untaint
 
    my $pid = int($1);

    return $pid;
};

sub running {
    my ($self) = @_;

    my $pid = &$read_pid($self);

    if ($pid) {
	my $res = PVE::ProcFSTools::check_process_running($pid) ? 1 : 0;
	return wantarray ? ($res, $pid) : $res;
    }

    return wantarray ? (0, 0) : 0;
}

sub stop {
    my ($self) = @_;

    my $pid = &$read_pid($self);

    return if !$pid;

    if (PVE::ProcFSTools::check_process_running($pid)) {
	kill(15, $pid); # send TERM signal
	# give some time
	my $wait_time = $self->{stop_wait_time} || 5;
	my $running = 1;
	for (my $i = 0; $i < $wait_time; $i++) {
	    $running = PVE::ProcFSTools::check_process_running($pid);
	    last if !$running;
	    sleep (1);
	}

	syslog('err', "server still running - send KILL") if $running;

	# to be sure
	kill(9, $pid);
	waitpid($pid, 0);
    }

    if (-f $self->{pidfile}) {
	eval {
	    # try to get the lock
	    &$lockpidfile($self);
	    &$server_cleanup($self);
	};
	if (my $err = $@) {
	    &$log_err("cleanup failed - $err");
	}
    }
}

sub register_start_command {
    my ($self, $description) = @_;

    my $class = ref($self);

    $class->register_method({
	name => 'start',
	path => 'start',
	method => 'POST',
	description => $description || "Start the daemon.",
	parameters => {
	    additionalProperties => 0,
	    properties => {
		debug => {
		    description => "Debug mode - stay in foreground",
		    type => "boolean",
		    optional => 1,
		    default => 0,
		},
	    },
	},
	returns => { type => 'null' },

	code => sub {
	    my ($param) = @_;

	    $self->start($param->{debug});

	    return undef;
	}});  
}

my $reload_daemon = sub {
    my ($self, $use_hup) = @_;

    if ($self->{env_restart_pve_daemon}) {
	$self->start();
    } else {
	my ($running, $pid) = $self->running(); 
	if (!$running) {
	    $self->start();
	} else {
	    if ($use_hup) {
		syslog('info', "send HUP to $pid");
		kill 1, $pid;
	    } else {
		$self->stop();
		$self->start();
	    }
	}
    }
};

sub register_restart_command {
    my ($self, $use_hup, $description) = @_;

    my $class = ref($self);

    $class->register_method({
	name => 'restart',
	path => 'restart',
	method => 'POST',
	description => $description || "Restart the daemon (or start if not running).",
	parameters => {
	    additionalProperties => 0,
	    properties => {},
	},
	returns => { type => 'null' },

	code => sub {
	    my ($param) = @_;

	    &$reload_daemon($self, $use_hup);

	    return undef;
	}});		   
}

sub register_reload_command {
    my ($self, $description) = @_;

    my $class = ref($self);

    $class->register_method({
	name => 'reload',
	path => 'reload',
	method => 'POST',
	description => $description || "Reload daemon configuration (or start if not running).",
	parameters => {
	    additionalProperties => 0,
	    properties => {},
	},
	returns => { type => 'null' },

	code => sub {
	    my ($param) = @_;

	    &$reload_daemon($self, 1);

	    return undef;
	}});		   
}

sub register_stop_command {
    my ($self, $description) = @_;

    my $class = ref($self);

    $class->register_method({
	name => 'stop',
	path => 'stop',
	method => 'POST',
	description => $description || "Stop the daemon.",
	parameters => {
	    additionalProperties => 0,
	    properties => {},
	},
	returns => { type => 'null' },

	code => sub {
	    my ($param) = @_;
	    
	    $self->stop();

	    return undef;
	}});		   
}

sub register_status_command {
    my ($self, $description) = @_;

    my $class = ref($self);

    $class->register_method({
	name => 'status',
	path => 'status',
	method => 'GET',
	description => "Get daemon status.",
	parameters => {
	    additionalProperties => 0,
	    properties => {},
	},
	returns => { 
	    type => 'string',
	    enum => ['stopped', 'running'],
	},
	code => sub {
	    my ($param) = @_;

	    return $self->running() ? 'running' : 'stopped';
	}});
}

# some useful helper

sub create_reusable_socket {
    my ($self, $port, $host) = @_;

    die "no port specifed" if !$port;

    my ($socket, $sockfd);

    if (defined($sockfd = $ENV{"PVE_DAEMON_SOCKET_$port"}) &&
	$self->{env_restart_pve_daemon}) {

	die "unable to parse socket fd '$sockfd'\n" 
	    if $sockfd !~ m/^(\d+)$/;
	$sockfd = $1; # untaint

	$socket = IO::Socket::INET->new;
	$socket->fdopen($sockfd, 'w') || 
	    die "cannot fdopen file descriptor '$sockfd' - $!\n";

    } else {

	$socket = IO::Socket::INET->new(
	    LocalAddr => $host,
	    LocalPort => $port,
	    Listen => SOMAXCONN,
	    Proto  => 'tcp',
	    ReuseAddr => 1) ||
	    die "unable to create socket - $@\n";

	# we often observe delays when using Nagle algorithm,
	# so we disable that to maximize performance
	setsockopt($socket, IPPROTO_TCP, TCP_NODELAY, 1);

	$ENV{"PVE_DAEMON_SOCKET_$port"} = $socket->fileno;
    }

    # remove FD_CLOEXEC bit to reuse on exec
    $socket->fcntl(Fcntl::F_SETFD(), 0);
    
    return $socket;
}


1;

