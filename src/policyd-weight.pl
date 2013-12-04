#!/usr/bin/env perl
#
# Copyright (c) 2005-2010 Robert Felber 
# (PC & IT Service Selling-IT, http://www.selling-it.de)
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA
#
# A copy of the GPL can be found at http://www.gnu.org/licenses/gpl.txt
#
# Parts of code based on postfix-policyd-spf by Meng Wen Wong, version 1.06,
# see http://spf.pobox.com/
#
# AUTHOR:  r.felber@selling-it.de
# DATE:    Tue Oct 19 20:31:50 CET 2009
# NAME:    policyd-weight
# VERSION: 0.1.15 beta-2
# URL:     http://www.policyd-weight.org/

# URL: https://github.com/palepurple/policyd-weight 

# minimal documentation: see INSTALL.txt


# begin
use strict;
use Fcntl;
use File::Spec;
use File::Path qw(make_path);
use Sys::Syslog qw(:DEFAULT setlogsock);
use Net::DNS;
use Net::IP;
use Net::DNS::Packet qw(dn_expand);
use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Select;
use Config;
use POSIX;
use Carp qw(cluck longmess);
use Geo::IP;

use vars qw($csock $s $tcp_socket $sock $new_sock $old_mtime);

our $VERSION   = "0.1.15 beta-2-github";
our $CVERSION  = 5;                 # cache interface version
our $CMD_DEBUG = 0;                 # -d switch 
our $KILL;                          # -k switch
our $STATS;                         # -s switch
our $DAEMONIZE;                     # start   action
our $RESTART;                       # restart action
our $RELOAD;                        # reload  action
our $STOP;                          # stop    action
our $FOREGROUND;
my  $run_action;                    # marker whether any action has been used
my  $conf;                          # path to config file

my $arg_iter;
my $ignore;
for(@ARGV)
{
    $arg_iter++;
    next if ($_ eq $ignore);
    $ignore = '';
    if($_ eq "-d")
    {
        $^W        = 1;
        $CMD_DEBUG = 1;
    }
    elsif($_ eq '-f')
    {
        if( -f $ARGV[$arg_iter])
        {
            $conf = $ARGV[$arg_iter];
            $ignore = $ARGV[$arg_iter];
            next;
        }
        else
        {
            mylog(error => "configfile ".$ARGV[$arg_iter]." doesn't exist\n");
            die("configfile: $ARGV[$arg_iter] doesn't exist");
        }
    }
    elsif($_ eq '-k')
    {
        $KILL  = 1;   
    }
    elsif($_ eq '-s')
    {
        $STATS = 1;
    }
    elsif($_ eq '-D')
    {
        $FOREGROUND = 1;
    }
    elsif($_ =~ /-[-]*h/)
    {
        usage();
    }
    elsif($_ =~ /-[-]*v/)
    {
        my $net_dns_ver = Net::DNS->version;
        my $os          = `uname -rs`;
        print <<EOF;
policyd-weight version: $VERSION, CacheVer: $CVERSION
Perl version:           $]
Net::DNS version:       $net_dns_ver
OS:                     $os
EOF
        exit;
    }
    elsif($_ eq "start")
    {
        usage() if ($run_action);

        if(!($< == 0 || $CMD_DEBUG))
        {
            die "You must be root in order to use \"start\"!\n";
        }

        $DAEMONIZE  = 1;
        $run_action = 1;
    }
    elsif($_ eq "defaults")
    {
        my $del;
        open(POLW, "<$0") || die "open: $0: $!\n";
        print "# ----------------------------------------------------------------\n";
        print "#  policyd-weight configuration (defaults) Version $VERSION \n";
        print "# ----------------------------------------------------------------\n";
        while (<POLW>)
        {
            if (/^#--BEGIN_CONFDEF/) 
            {
                $del = 1;
                next;
            }
            if ($del) 
            {
                if (/^#--END_CONFDEF/) 
                {
                     last;
                } 
                else 
                {
                     $_ =~ s/^my /   /;
                     print $_;
                }
             }
        }
        close(POLW);
        exit;
    }
    elsif($_ eq "restart")
    {
        usage() if ($run_action);

        if(!($< == 0 || $CMD_DEBUG))
        { 
            die "You must be root in order to use \"restart\"!\n";
        }

        $STOP       = 1;
        $RESTART    = 1;
        $DAEMONIZE  = 1;
        $run_action = 1;
    }
    elsif($_ eq "stop")
    {
        usage() if ($run_action);

        if(!($< == 0 || $CMD_DEBUG))
        {
            die "You must be root in order to use \"stop\"!\n";
        }

        $DAEMONIZE  = 1;
        $STOP       = 1;
        $run_action = 1;
    }
    elsif($_ eq "reload")
    {
        usage() if ($run_action);

        if(!($< == 0 || $CMD_DEBUG))
        {
            die "You must be root in order to use \"reload\"!\n";
        }

        $RELOAD = 1;
    }
    else
    {
        print "policyd-weight: unknown option $_\n";
        usage(1);
    }
    
}


sub usage
{
    my $ret = shift;

    print <<EOF;
Usage: policyd-weight [-option -option2 <arg>] [stop|start|restart|defaults]
Args in [ ] are optional.

Options
    -D                   Don't detach master - run master in foreground
    -d                   Debug, don't daemonize, log to STDOUT
    -f /path/to/file     Specify a configuration file
    -h                   This help
    -k                   Kill cache instance
    -s                   Show  cache entries and exit. With -d show debug
                         cache entries
    -v                   Show version and exit

Actions
    stop                 Stops the policyd-weight  daemon, add -k to also
                         Stop the cache. In addition with -d -k it stops
                         the debug cache.

    start                Starts the policyd-weight daemon. Add -d to start a 
                         debug session in foregorund.

    restart              Restarts  policyd-weight. Together with -d it
                         restarts a debug session in foreground.

    reload               Reload the configuration file

    defaults             Output default configuration

If no action is given it waits for data on STDIN.
WARNING: do NOT use options or actions in master.cf!
EOF

    exit($ret);
}

if($CMD_DEBUG)
{
    $^W = 1;
    mylog(debug => "policyd-weight version: ".$VERSION);
    mylog(debug => "CacheVer: $CVERSION");
    mylog(debug => "System: " . `uname -a`);
    mylog(debug => "Perl version: ".$]."\n");
}

#
# store signal-name to number conversions for better accessibility
#
our %sig_list;
my  $i;
foreach(split(' ', $Config{sig_name})) 
{
    $sig_list{$_} = $i++;
}


#
# Print Module Versions if -d requested
#
if($CMD_DEBUG)
{
    mylog(debug => "Net::DNS version: " . Net::DNS->version) ;
}


# don't let warnings confuse the SMTP, feed die() lines to syslog
$SIG{__DIE__} = sub {
    mylog(warning=>"err: @_");
};

# ----------------------------------------------------------
#           configuration (defaults)
# ----------------------------------------------------------
# don't make changes here, instead use/create /etc/policyd-weight.conf
# NOTE: use perl syntax inclusive `;' in configuration files.
#
#--BEGIN_CONFDEF

my $DEBUG        = 0;               # 1 or 0 - don't comment

my $REJECTMSG    = "550 Mail appeared to be SPAM or forged. Ask your Mail/DNS-Administrator to correct HELO and DNS MX settings or to get removed from DNSBLs";

my $REJECTLEVEL  = 1;               # Mails with scores which exceed this
                                    # REJECTLEVEL will be rejected

my $DEFER_STRING = 'IN_SPAMCOP= BOGUS_MX='; 
                                    # A space separated case-sensitive list of
                                    # strings on which if found in the $RET
                                    # logging-string policyd-weight changes
                                    # its action to $DEFER_ACTION in case
                                    # of rejects.
                                    # USE WITH CAUTION!
                                    # DEFAULT: "IN_SPAMCOP= BOGUS_MX="


my $DEFER_ACTION = '450';           # Possible values: DEFER_IF_PERMIT,
                                    # DEFER_IF_REJECT, 
                                    # 4xx response codes. See also access(5)
                                    # DEFAULT: 450

my $DEFER_LEVEL  = 5;               # DEFER mail only up to this level
                                    # scores greater than DEFER_LEVEL will be
                                    # rejected
                                    # DEFAULT: 5

my $DNSERRMSG         = '450 No DNS entries for your MTA, HELO and Domain. Contact YOUR administrator';

my $dnsbl_checks_only = 0;          # 1: ON, 0: OFF (default)
                                    # If ON request that ALL clients are only
                                    # checked against RBLs

my @dnsbl_checks_only_regexps = (
    # qr/[^.]*(exch|smtp|mx|mail).*\..*\../,
    # qr/yahoo.com$/
);                                  # specify a comma-separated list of regexps
                                    # for client hostnames which shall only
                                    # be RBL checked. This does not work for
                                    # postfix' "unknown" clients.
                                    # The usage of this should not be the norm
                                    # and is a tool for people which like to
                                    # shoot in their own foot.
                                    # DEFAULT: empty
                                    

my $LOG_BAD_RBL_ONLY  = 1;          # 1: ON (default), 0: OFF
                                    # When set to ON it logs only RBLs which
                                    # affect scoring (positive or negative)
                                    
## DNSBL settings
my @dnsbl_score = (
#    HOST,                    HIT SCORE,  MISS SCORE,  LOG NAME
    'pbl.spamhaus.org',       3.25,          0,        'DYN_PBL_SPAMHAUS',
    'sbl-xbl.spamhaus.org',   4.35,       -1.5,        'SBL_XBL_SPAMHAUS',
    'bl.spamcop.net',         3.75,       -1.5,        'SPAMCOP',
    'dnsbl.sorbs.net',        3.75,       -1.5,        'DNSBL_SORBS',
    'ix.dnsbl.manitu.net',    4.35,          0,        'IX_MANITU',
    'tor.ahbl.org',           2.50,          0,        'TOR_ANBL',
    #'rbl.ipv6-world.net',     4.25,          0,        'IPv6_RBL'  #don't use, kept for testing failures!
);

my $MAXDNSBLHITS  = 2;  # If Client IP is listed in MORE
                        # DNSBLS than this var, it gets
                        # REJECTed immediately

my $MAXDNSBLSCORE = 8;  # alternatively, if the score of
                        # DNSBLs is ABOVE this
                        # level, reject immediately

my $MAXDNSBLMSG   = '550 Your MTA is listed in too many DNSBLs';

## RHSBL settings
my @rhsbl_score = (
    'multi.surbl.org',             4,        0,        'SURBL',
    'rhsbl.ahbl.org',              4,        0,        'AHBL',
    'dsn.rfc-ignorant.org',        3.5,      0,        'DSN_RFCI',
    'postmaster.rfc-ignorant.org', 0.1,      0,        'PM_RFCI',
    'abuse.rfc-ignorant.org',      0.1,      0,        'ABUSE_RFCI'
);

my $BL_ERROR_SKIP     = 2;  # skip a RBL if this RBL had this many continuous
                            # errors

my $BL_SKIP_RELEASE   = 10; # skip a RBL for that many times

## cache stuff
my $LOCKPATH          = '/tmp/.policyd-weight/';    # must be a directory (add
                                                    # trailing slash)

my $SPATH             = $LOCKPATH.'/polw.sock';     # socket path for the cache
                                                    # daemon. 

my $MAXIDLECACHE      = 60; # how many seconds the cache may be idle
                            # before starting maintenance routines
                            # NOTE: standard maintenance jobs happen
                            # regardless of this setting.

my $MAINTENANCE_LEVEL = 5;  # after this number of requests do following
                            # maintenance jobs:
                            # checking for config changes

# negative (i.e. SPAM) result cache settings ##################################

my $CACHESIZE       = 2000; # set to 0 to disable caching for spam results. 
                            # To this level the cache will be cleaned.

my $CACHEMAXSIZE    = 4000; # at this number of entries cleanup takes place

my $CACHEREJECTMSG  = '550 temporarily blocked because of previous errors';

my $NTTL            = 1;    # after NTTL retries the cache entry is deleted

my $NTIME           = 30;   # client MUST NOT retry within this seconds in order
                            # to decrease TTL counter

# positve (i.,e. HAM) result cache settings ###################################

my $POSCACHESIZE    = 1000; # set to 0 to disable caching of HAM. To this number
                            # of entries the cache will be cleaned

my $POSCACHEMAXSIZE = 2000; # at this number of entries cleanup takes place

my $POSCACHEMSG     = 'using cached result';

my $PTTL            = 60;   # after PTTL requests the HAM entry must
                            # succeed one time the RBL checks again

my $PTIME           = '3h'; # after $PTIME in HAM Cache the client
                            # must pass one time the RBL checks again.
                            # Values must be nonfractal. Accepted
                            # time-units: s, m, h, d

my $TEMP_PTIME      = '1d'; # The client must pass this time the RBL
                            # checks in order to be listed as hard-HAM
                            # After this time the client will pass
                            # immediately for PTTL within PTIME


## DNS settings
my $DNS_RETRIES     = 2;    # Retries for ONE DNS-Lookup

my $DNS_RETRY_IVAL  = 2;    # Retry-interval for ONE DNS-Lookup

my $MAXDNSERR       = 3;    # max error count for unresponded queries
                            # in a complete policy query

my $MAXDNSERRMSG    = 'passed - too many local DNS-errors';

my $PUDP            = 0;    # persistent udp connection for DNS queries.
                            # broken in Net::DNS version 0.51. Works with
                            # Net::DNS 0.53; DEFAULT: off

my $USE_NET_DNS     = 0;    # Force the usage of Net::DNS for RBL lookups.
                            # Normally policyd-weight tries to use a faster
                            # RBL lookup routine instead of Net::DNS

my $NS              = '';   # A list of space separated NS IPs
                            # This overrides resolv.conf settings
                            # Example: $NS = '1.2.3.4 1.2.3.5';
                            # DEFAULT: empty

my $IPC_TIMEOUT     = 2;    # timeout for receiving from cache instance

my $TRY_BALANCE     = 0;    # If set to 1 policyd-weight closes connections
                            # to smtpd clients in order to avoid too many
                            # established connections to one policyd-weight
                            # child

# scores for checks, WARNING: they may manipulate eachother
# or be factors for other scores.
#                                       HIT score, MISS Score
my @client_ip_eq_helo_score          = (1.5,       -1.25 );
my @helo_score                       = (1.5,       -2    );
my @helo_from_mx_eq_ip_score         = (1.5,       -3.1  );
my @helo_numeric_score               = (2.5,        0    );
my @from_match_regex_verified_helo   = (1,         -2    );
my @from_match_regex_unverified_helo = (1.6,       -1.5  );
my @from_match_regex_failed_helo     = (2.5,        0    );
my @helo_seems_dialup                = (1.5,        0    );
my @failed_helo_seems_dialup         = (2,          0    );
my @helo_ip_in_client_subnet         = (0,         -1.2  );
my @helo_ip_in_cl16_subnet           = (0,         -0.41 );
my @client_seems_dialup_score        = (3.75,       0    );
my @from_multiparted                 = (1.09,       0    );
my @from_anon                        = (1.17,       0    );
my @bogus_mx_score                   = (2.1,        0    );
my @random_sender_score              = (0.25,       0    );
my @rhsbl_penalty_score              = (3.1,        0    );
my @enforce_dyndns_score             = (3,          0    );



## GeoIP Settings
# Add additional country definitions to the below - see
#  http://www.iso.org/iso/country_codes/iso_3166_code_lists/english_country_names_and_code_elements.htm
#
my @geoip_score = (
    # ISO-3166 COUNTRY CODE, NO MATCH, MATCH, LOG NAME
    "UK",                       0,      -1,     "UK",
    "CN",                       0,       2,     "CHINA",
    "RU",                       0,       2,     "RUSSIA",
);

my $geoip_scoring_enabled = 0; # 0 = do not perform geoip checks (DEFAULT), 1 = enable


my $VERBOSE = 0;

my $ADD_X_HEADER        = 1;    # Switch on or off an additional 
                                # X-policyd-weight: header
                                # DEFAULT: on


my $DEFAULT_RESPONSE    = 'DUNNO default'; # Fallback response in case
                                           # the weighted check didn't
                                           # return any response (should never
                                           # appear).



#
# Syslogging options for verbose mode and for fatal errors.
# NOTE: comment out the $syslog_socktype line if syslogging does not
# work on your system.
#

my $syslog_socktype = 'unix';   # inet, unix, stream, console

my $syslog_facility = "mail";
my $syslog_options  = "pid";
my $syslog_priority = "info";
my $syslog_ident    = "postfix/policyd-weight";


#
# Process Options
#
my $USER            = "polw";      # User must be a username, no UID

my $GROUP           = "";          # specify GROUP if necessary
                                   # DEFAULT: empty, will be initialized as 
                                   # $USER

my $MAX_PROC        = 50;          # Upper limit if child processes
my $MIN_PROC        = 3;           # keep that minimum processes alive

my $TCP_PORT        = 12525;       # The TCP port on which policyd-weight 
                                   # listens for policy requests from postfix

my $BIND_ADDRESS    = '127.0.0.1'; # IP-Address on which policyd-weight will
                                   # listen for requests.
                                   # You may only list ONE IP here, if you want
                                   # to listen on all IPs you need to say 'all'
                                   # here. Default is '127.0.0.1'.
                                   # You need to restart policyd-weight if you
                                   # change this.

my $SOMAXCONN       = 1024;        # Maximum of client connections 
                                   # policyd-weight accepts
                                   # Default: 1024
                                   

my $CHILDIDLE       = 240;         # how many seconds a child may be idle before
                                   # it dies.

my $PIDFILE         = "/var/run/policyd-weight.pid";

#--END_CONFDEF

# Ensure $USER is valid.
if(!getpwnam($USER)) {
    if(!$CMD_DEBUG) {
        die("\$USER does not appear to be valid ($USER); please fix config");
    }
    $USER=getpwuid($>);
}
if(!getgrnam($GROUP)) {
    if(!$CMD_DEBUG) {
        die("\$GROUP does not appear to be valid ($GROUP); please fix config");
    }
    $GROUP=getgrgid(getgid());
}

$0 = "policyd-weight (master)";
my %cache;
my %poscache;
my $my_PTIME;
my $my_TEMP_PTIME;

if(!($conf))
{
    if( -f "/etc/policyd-weight.conf")
    {
        $conf = "/etc/policyd-weight.conf";
    }
    elsif( -f "/etc/postfix/policyd-weight.cf")
    {
        $conf = "/etc/postfix/policyd-weight.cf";
    }
    elsif( -f "/usr/local/etc/policyd-weight.conf")
    {
        $conf = "/usr/local/etc/policyd-weight.conf";
    }
    elsif( -f "policyd-weight.conf")
    {
        $conf = "policyd-weight.conf";
    }
    else {
        if($CMD_DEBUG) { 
            mylog(debug => "No config file defined/found");
        }
        else {
            warn "No config file defined/found\n";
        }
    }

}

my $conf_err;
my $conf_str;
our $old_mtime;
if($conf) 
{
    if(sprintf("%04o",(stat($conf))[2]) !~ /(7|6|3|2)$/)
    {
        if(open(CONF, $conf))
        {
            read(CONF,$conf_str,-s CONF);
            close(CONF);

            #XXX taint $conf_str as $< enables taint mode
            ($conf_str) = $conf_str =~ m/(.*)/s;

            eval $conf_str;
            if($@)
            {
                $conf_err = "syntax error in file $conf: ".$@;
            }
            else
            {
                $old_mtime = (stat($conf))[9];
            }
        }
        else
        {
            $conf_err = "could not open $conf: $!";
        }
    }
    else
    {
        $conf_err = "$conf is world-writeable!";
    }
}
else
{
    $conf = "default settings"; # don't change! required by cache maintenance
}


our $STAYALIVE;

if($CMD_DEBUG == 1 )
{
    $DEBUG = 1;

    if($conf_str) { 
        $conf_str =~ s/\#.*?(\n)/$1/gs;
        $conf_str =~ s/\n+/\n/g;
        mylog(debug => "config: $conf\n".$conf_str); 
    }
    $SPATH   .= ".debug";
    
    # chose /tmp for debug pidfiles only if user is not root
    # if root would store debug pids also in /tmp we would be
    # open to race attacks
    if($< != 0)
    {
        $PIDFILE = "/tmp/policyd-weight.pid.debug";
    }
    else
    {
        $PIDFILE .= ".debug";
    }

    mylog(debug => " using port ".++$TCP_PORT);
    mylog(debug => " running as USER:  $USER");
    mylog(debug => " running as GROUP: $GROUP");
    mylog(debug => " issuing user:  ".getpwuid($<));
    mylog(debug => " issuing group: ".getgrgid(getgid()));
}

$conf_str = "";



#
# check for nasty symlinks
#
check_symlnk('master: init:',
    $LOCKPATH, $PIDFILE, $SPATH, "$LOCKPATH/cache_lock");


# send HUP to kids if $RELOAD
if($RELOAD)
{
    local $SIG{HUP} = 'IGNORE';

    open(PF, $PIDFILE) or die "Couldn't open $PIDFILE: $!";
    my $pid = <PF>;
    close(PF);

    if(!($pid > 0)) { die "pid $pid seems to be wrong" };

    print "sending ".-$sig_list{HUP}." to $pid\n";

    kill (-$sig_list{HUP}, $pid) or die "err: $!";

    exit;
}


# ----------------------------------------------------------
#                initialization
# ----------------------------------------------------------


#
# This process runs as a daemon, so it can't log to a terminal. Use
# syslog so that people can actually see our messages.
#
if($CMD_DEBUG != 1)
{
    setlogsock($syslog_socktype) or die 
        "setlogsock: $syslog_socktype: $!. If you are on Solaris you might want to set \$syslog_socktype = 'stream';";
    openlog($syslog_ident, $syslog_options, $syslog_facility) or die "openlog: $!. If you are on Solaris you might want to set \$syslog_socktype = 'stream';";
}

if($KILL)
{

    if((-S $SPATH) && ($csock = IO::Socket::UNIX->new($SPATH)))
    {
        cache_query("kill");
        $csock->close if ($csock && $csock->connected);
        unlink $SPATH;
    }
    if(-S $SPATH)
    {
        mylog(warning=>"-k action but $SPATH still exists, deleting it");
        print STDERR "warning: -k action but $SPATH still exists, deleting it\n";
        unlink $SPATH or die $!;
    }
    if( -d $LOCKPATH.'/cache_lock')
    {
        mylog(warning=>'removing stale '.$LOCKPATH.'/cache_lock');
        print STDERR 'warning: removing stale '.$LOCKPATH.'/cache_lock';
        rmdir $LOCKPATH.'/cache_lock';
    }
    exit unless $STOP or $DAEMONIZE;
}

if($STATS)
{
    print "*** querying cache for content stats:\n";
    cache_query("stats");
    exit;
}


if(!($run_action))
{
    # don't unlink PIDFILE if policyd-weight
    # got called without arguments
    $STAYALIVE = 1;
}


# re-arrange signal handlers
$SIG{__DIE__} = sub {
    die @_ if index($_[0], 'ETIMEOUT') == 0;
    mylog(warning=>"err: init: @_");
    unlink $PIDFILE unless $STAYALIVE;
};
$SIG{'TERM'}  = sub { unlink $PIDFILE unless $STAYALIVE;
                      mylog(warning=>'Got SIGTERM. Daemon terminated.'); exit };

$SIG{'QUIT'}  = sub { unlink $PIDFILE unless $STAYALIVE;
                      mylog(warning=>"Got SIG@_. Daemon terminated."); exit };

$SIG{'INT'}   = sub { unlink $PIDFILE unless $STAYALIVE;
                      mylog(warning=>"Got SIG@_. Daemon terminated."); exit };

$SIG{'PIPE'}  = sub { unlink $PIDFILE;
                      mylog(warning=>"Got SIG@_. Daemon terminated."); exit };

$SIG{'SYS'}   = sub { unlink $PIDFILE;
                      mylog(warning=>"Got SIG@_. Daemon terminated."); exit }; 

$SIG{'USR1'}  = sub { unlink $PIDFILE;
                      mylog(warning=>"Got SIG@_. Daemon terminated."); exit };

$SIG{'USR2'}  = sub { unlink $PIDFILE;
                      mylog(warning=>"Got SIG@_. Daemon terminated."); exit };

if($SIG{'POLL'}) {
$SIG{'POLL'}   = sub { unlink $PIDFILE;
                      mylog(warning=>"Got SIG@_. Daemon terminated."); exit };
}

if($SIG{'UNUSED'})
{
$SIG{'UNUSED'} = sub { unlink $PIDFILE;
                      mylog(info=>"Got SIG@_. Daemon terminated."); exit };
}


#####
## core dumpers

$SIG{'SEGV'}  = sub { 
                      $SIG{'ABRT'} = '';
                      unlink $PIDFILE;
                      mylog(warning=>"Got @_:".longmess().
                        ". Daemon terminated.");
                      CORE::dump(); exit };

$SIG{'ILL'}   = sub { 
                      $SIG{"ABRT"} = '';
                      unlink $PIDFILE;
                      mylog(warning=>"Got @_:".longmess().
                        ". Daemon terminated."); 
                      CORE::dump; exit };

$SIG{'ABRT'}  = sub { unlink $PIDFILE;
                      mylog(warning=>"Got @_:".longmess().
                        ". Daemon terminated."); 
                      CORE::dump; exit };

$SIG{'FPE'}   = sub { 
                      $SIG{"ABRT"} = '';
                      unlink $PIDFILE;
                      mylog(warning=>"Got @_:".longmess().
                        ". Daemon terminated."); 
                      CORE::dump; exit };

$SIG{'BUS'}   = sub { 
                      $SIG{"ABRT"} = '';
                      unlink $PIDFILE;
                      mylog(warning=>"Got @_:".longmess().
                        ". Daemon terminated."); 
                      CORE::dump; exit };

$SIG{'HUP'}   = sub { conf_check('master'); };


#
# Log an error and abort.
#
sub fatal_exit {
  mylog(warning => "fatal_exit: @_");
  die "fatal: @_";
}

#
# Unbuffer standard output.
#
select((select(STDOUT), $| = 1)[0]);


if($VERBOSE == 1)
{
    mylog(debug=>"startup: using $conf");
}

my $RETANSW;

if($ADD_X_HEADER == 1)
{
    $RETANSW = "PREPEND X-policyd-weight:";
}
else
{
    $RETANSW = "DUNNO ";
}

if($conf_err)
{
    mylog(warning=>"conf-err: ".$conf_err);
    mylog(warning=>"conf-err: falling back to builtin defaults");
    $RETANSW = $RETANSW." using builtin defaults due to config-error";
}



our $res=Net::DNS::Resolver->new;
$res->retrans($DNS_RETRY_IVAL) unless $DNS_RETRY_IVAL eq "";
$res->retry($DNS_RETRIES)      unless $DNS_RETRIES    eq "";
# This is responsible for outputting the DNS query results ...
$res->debug(1)                 if     ($VERBOSE == 1);

if($NS && $NS =~ /\d/)
{
    my @ns = split(' ', $NS);
    $res->nameservers(@ns);
}


# watch the version string, I'm afraid that they change to x.x.x notation
if(Net::DNS->version() >= 0.50)
{
    $res->force_v4(1);  # force ipv4 usage, autodetection is broken till
                        # Net::DNS 0.53
}
else
{
    $res->igntc(1);    # ignore truncated packets if Net-DNS version is
                       # lower than 0.50
}


# keep udp socket open, don't waste time for socket creation.
# works with Net::DNS 0.53
$res->persistent_udp(1) if $PUDP == 1;

our %RTYPES = ( 'A' => 1, 'TXT' => 16 ); # see RFC 1035
our $s;

if($res)
{
    my $ns = (($res->nameserver)[0]);
    if(!($s = IO::Socket::INET->new( 
                                PeerAddr => $ns,
                                PeerPort => '53',
                                Proto    => 'udp'
                              )
    ))
    {
        mylog(warning=>"could not open RBL Lookup Socket to $ns: $@ $!");
        $USE_NET_DNS = 1;
    }
}



# ----------------------------------------------------------
#                 main
# ----------------------------------------------------------

#
# Receive a bunch of attributes, evaluate the policy, send the result.
#

our $accepted     = "UNDEF";
our $blocked      = "UNDEF";
our $my_REJECTMSG = $REJECTMSG;
our %bl_err;
our $skip_rel;


# cd to a coredump dir, if it exists 

chdir "$LOCKPATH/cores/master";


my %attr;
if(!($DAEMONIZE))
{
    while (<STDIN>)
    {
        my $string = $_;
        my $action = parse_input($string);
        
        if($action)
        {
            print STDOUT $action;
            %attr = ();
        }
    }
}
else
{

##############################################################################
#
# DAEMON
#
##############################################################################
    if($STOP && (!(-f $PIDFILE)))
    {
        print STDERR "No pidfile, expected it at $PIDFILE!\n";
        exit 1;
    }

    if( -f $PIDFILE) 
    {
        open(PF, $PIDFILE) || die  $!;
        my $oldpid = <PF>;
        close(PF);

        if($STOP && $oldpid)
        {
            if(my $ret = kill(-$sig_list{'TERM'}, $oldpid))
            {
                print "terminating ";
                mylog(info=>"Daemon terminated.");
            }
            else
            {
                kill(-$sig_list{'KILL'}, $oldpid);
                print "killed\n";
                mylog(info=>"Abnormal exit. Daemon killed forcingly.");
            }

            unlink $PIDFILE;
            if(!$RESTART)
            {
                print " ... done\n";
                exit;
            }
        }

        my $i;

        while($oldpid && kill(0, $oldpid))
        {
            if(!$RESTART)
            {
                mylog(warning=>"Process already running");
                print STDERR "Process already running\n";
                exit -1;
            }
            autoflush STDOUT 1;
            print ".";

            if($i++ > 5)
            {
                $STAYALIVE = 1;
                mylog(warning=>"Couldn't remove $PIDFILE, a process with pid $oldpid exists! Use \"restart\" to force.\n");
                die "Couldn't remove $PIDFILE, a process with pid $oldpid exists! Use \"restart\" to force.\n";
            }
            sleep 1;
        }
        print " done\n";
    }

    create_lockpath("daemon");

    if($BIND_ADDRESS && $BIND_ADDRESS !~ /^[ \t]*all[ \t]*$/i)
    {
        $tcp_socket = IO::Socket::INET->new(    Proto       => 'tcp',
                                                LocalHost   => $BIND_ADDRESS,
                                                LocalPort   => $TCP_PORT,
                                                Listen      => $SOMAXCONN,
                                                Reuse       => 1,
                                                Blocking    => 0) or 
                                        die "master: bind $TCP_PORT: $@ $!";
    }
    else
    {
        $tcp_socket = IO::Socket::INET->new(    Proto       => 'tcp',
                                                LocalPort   => $TCP_PORT,
                                                Listen      => $SOMAXCONN,
                                                Reuse       => 1,
                                                Blocking    => 0) or 
                                        die "master: bind $TCP_PORT: $@ $!";
    }

    # XXX: do we really need that? I used it for a chance of closing
    # sockets when spawning caches and the like. 
    fcntl($tcp_socket, F_SETFD, FD_CLOEXEC); 

 
    open(PF, ">".$PIDFILE) or die $!;

# drop privileges
    if(!($CMD_DEBUG))
    {

        my $uname  = getpwnam($USER)  or die "User $USER doesn't exist!";
        my $gname  = getgrnam($GROUP) or die "Group $GROUP doesn't exist!";

        my $runame = getpwuid($<)     or die $!;
        my $rgname = getgrgid($()     or die $!;


        # XXX: You'll get nightmares if you change stuff here! *voodoospell*
        $! = '';
        
        # this first variant uses different approaches on plattforms.
        # freebsd/linux uses setresgid + setgroups, other bsd, Mac OS X use 
        # obviously setregid + setgroups
        ($(,$)) = ($gname, "$gname $gname");
        if($!)
        {
            
            $! = '';
            # last try. Implementation variant not clear on all plattforms
            $( = $gname;
                die "($<)($>): set GID to $gname: $!" if $!;
            
            $) = "$gname $gname";
                die "($<)($>): set EGID to $gname: $!" if $!;
        }
        
        ($<, $>) = ($uname, $uname);
        if($!)
        {
            $! = '';

            # this turns on taint mode, too. see man perlsec!
            $< = $uname;
                die "set UID to $uname: $!" if $!;

            $> = $uname;
                die "set EUID to $uname: $!" if $!;
        }


        # create directories for chdir in order
        # to find core dumps an such
        if(!(-d "$LOCKPATH/cores/"))
        {
            mkdir "$LOCKPATH/cores/" or die
            "master: error while creating $LOCKPATH/cores/: $!";
        }
        if(!(-d "$LOCKPATH/cores/master"))
        {
            mkdir "$LOCKPATH/cores/master" or die
            "master: error while creating $LOCKPATH/cores/master: $!";
        }
        if(!(-d "$LOCKPATH/cores/cache"))
        {
            mkdir "$LOCKPATH/cores/cache" or die
            "master: error while creating $LOCKPATH/cores/cache: $!";
        }


        chdir "$LOCKPATH/cores/master" or 
            die "master: chdir $LOCKPATH/cores/master: $!";

        if(!($FOREGROUND))
        {
            defined(my $pid = fork)   or die "Can't fork: $!";
            exit if $pid;

# daemonized

            setsid                    or die "Can't start a new session: $!";
            open STDIN, '/dev/null'   or die "Can't read /dev/null: $!";
            open STDERR, '>/dev/null' or die "Can't write to /dev/null: $!";
            open STDOUT, '>/dev/null' or die "Can't write to /dev/null: $!"; 
        }
        
        mylog(info=>"policyd-weight $VERSION started and daemonized. " .
                    "conf:$conf; "                    . 
                    "GID:$( EGID:$) UID:$< EUID:$>; " .
                    "taint mode: " . ${^TAINT}
              );
    }

    print PF $$ or die "err $!\n";
    close PF    or die "err $!\n";

    my %childs;     # maintenance hash for cleaning up children
    my %avail;      # hash to know which client is available
    my %pipes;      # hash to maintain pid -> pipe associations

    cache_query("start"); # pre-launch cache
 
    our $select_to;

   
    my $readable_handles = new IO::Select();
    my $new_tcp_readable;

    $tcp_socket->autoflush(1);
    $readable_handles->add($tcp_socket);

    my $waitedpid;
    my $parentpid = $$;

    sub REAPER {
        my $waitedpid;
        while($waitedpid = waitpid(-1, WNOHANG))
        {
            last if $waitedpid == -1;
            mylog(info=>"master: child $waitedpid exited");
            delete($childs{$waitedpid});
            delete($avail{$waitedpid});
            delete($pipes{$waitedpid});
            if(!(keys(%avail) > 0))
            {
                $readable_handles->add($tcp_socket);
            }
        }
        $SIG{CHLD} = \&REAPER;
    }
    $SIG{CHLD} = \&REAPER;


    $SIG{'TERM'}  = sub { 
        foreach(keys(%childs))
        {
            kill($sig_list{TERM}, $_);
        }
        unlink $PIDFILE;
        exit 0; 
    };

    use vars qw/$child/;
    use vars qw/$parent/;
    my $sigset;
    my $old_sigset;

    while(1)
    {
        # process SIGCHLD signals
        if($old_sigset)
        {
            unless (defined sigprocmask(SIG_UNBLOCK, $old_sigset)) 
            {
                mylog(warning=>"master: Could not unblock SIGCHLD");
            }
        }

        # wait for data on all sockets
        ($new_tcp_readable) =
            IO::Select->select($readable_handles, undef, undef, undef);
        
        # block SIGCHLD signals, avoid raceconditions and coredumps
        $sigset     = POSIX::SigSet->new(SIGCHLD);
        $old_sigset = POSIX::SigSet->new;

        unless (defined sigprocmask(SIG_BLOCK, $sigset, $old_sigset))
        {
            mylog(warning=>"master: Could not block SIGCHLD");
        }

        my $max_proc_msg;        

        # process socket data
        foreach my $sock (@$new_tcp_readable)
        {
            if($sock == $tcp_socket)
            {
                # let children handle it if they are available
                if (keys(%avail) > 0)
                {
                    $readable_handles->remove($tcp_socket);
                    next;
                }

                # don't spawn new children if MAX_PROC reached
                if(keys %childs >= $MAX_PROC)
                { 
                    if( (!($max_proc_msg)) )
                    {
                        mylog(warning=>"master: MAX_PROC ($MAX_PROC) reached");
                    }

                    $max_proc_msg = 1;
                    $readable_handles->remove($tcp_socket);
                    next; 
                }

                # open a socketpair for control communication with the
                # soon to be spawned child
                ($child, $parent) = 
                    IO::Socket->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC) or
                    mylog(warning=>"master: socketpair: $@ $!");
                 
                $child->autoflush(1);
                $parent->autoflush(1);

                # check for configuration changes before we spawn a new child
                conf_check("master");

                # attempt to fork a new child
                defined(my $pid = fork) or die "cannot fork: $!";

                # parent stuff
                if ($pid)
                {
                    $pipes{$pid} = $child;
                    $readable_handles->add($pipes{$pid});
                    $readable_handles->add($tcp_socket);
                    $parent->close;
                    $childs{$pid} = 1;
                    $avail{$pid}  = 1;
                    next;
                }

##############################################################################
#
# DAEMON CHILDREN
#
##############################################################################
                $0 = "policyd-weight (child)";

                $SIG{'TERM'} = sub {
                    eval
                    {
                        local $SIG{ALRM} = sub { die "ETIMEOUT" };
                        alarm $IPC_TIMEOUT;
                        print $parent ("$$ 0\n");
                        $parent->recv(my $ans, 1024);
                        alarm 0;
                    };
                    exit;
                };
                our $die_r;
                $SIG{__DIE__} = sub {
                    die @_ if index($_[0], 'ETIMEOUT') == 0;
                    die @_ if @_ eq $die_r;
                    $die_r = @_;
                    mylog(warning=>"child: err: @_" );
                    eval
                    {
                        local $SIG{ALRM} = sub { die "ETIMEOUT" };
                        alarm $IPC_TIMEOUT;
                        print $parent ("$$ 0\n");
                        $parent->recv(my $ans, 1024);
                        alarm 0;
                    };
                };
                $SIG{INT} = sub {
                    eval
                    {
                        local $SIG{ALRM} = sub { die "ETIMEOUT" };
                        alarm $IPC_TIMEOUT;
                        print $parent ("$$ 0\n");
                        $parent->recv(my $ans, 1024);
                        alarm 0;
                    };
                    exit;
                };
                $SIG{'HUP'} = sub {
                    conf_check('child');
                };


                $SIG{'PIPE'} = sub {
                    mylog(warning=>"Got SIG@_. Child $$ terminated.");
                    die;
                };
                $SIG{'SYS'}   = sub {
                    mylog(warning=>"Got SIG@_. Child $$ terminated.");
                    die 
                };
                $SIG{'USR1'}  = sub {
                    mylog(warning=>"Got SIG@_. Child $$ terminated.");
                    die 
                };
                $SIG{'USR2'}  = sub {
                    mylog(warning=>"Got SIG@_. Child $$ terminated.");
                    die
                };
                if($SIG{'POLL'}) {
                    $SIG{'POLL'}   = sub {
                      mylog(warning=>"Got SIG@_. Child $$ terminated."); die
                    };
                }
                if($SIG{'UNUSED'}) {
                    $SIG{'UNUSED'} = sub {
                      mylog(info=>"Got SIG@_. Child $$ terminated."); die
                    };
                }
                

                # core dumpers

                $SIG{'SEGV'}  = sub {
                    $SIG{'ABRT'} = '';
                    delete($SIG{'ABRT'});
                    mylog(warning=>"Got @_:".longmess().
                        ". Child $$ terminated");
                    die
                };
                $SIG{'ILL'}   = sub {
                      $SIG{"ABRT"} = '';
                      mylog(warning=>"Got @_:".longmess().
                        ". Child $$ terminated.");
                      die 
                };
                $SIG{'ABRT'}  = sub {
                      mylog(warning=>"Got @_:".longmess().
                        ". Child $$ terminated.");
                      die 
                };
                $SIG{'FPE'}   = sub {
                      $SIG{"ABRT"} = '';
                      mylog(warning=>"Got @_:".longmess().
                        ". Child $$ terminated.");
                      die
                };
                $SIG{'BUS'}   = sub {
                      $SIG{"ABRT"} = '';
                      mylog(warning=>"Got @_:".longmess().
                        ". Child $$ terminated.");
                      die
                };


                mylog(info=>'child: spawned');

                if($res)
                {
                    if($s && $s->connected)
                    {
                        $s->close; # don't use inherited DNS sockets
                    }
                    my $ns = (($res->nameserver)[0]);
                    if(!($s = IO::Socket::INET->new( 
                                     PeerAddr => $ns,
                                     PeerPort => '53',
                                     Proto    => 'udp'))
                      )
                    {
                        mylog(warning=>
                            "child: could not open RBL Lookup Socket to $ns: $@ $!");

                        $USE_NET_DNS = 1;
                    }
                }

                my $readable_handles = new IO::Select();
                   $readable_handles->add($parent);
                   $readable_handles->add($tcp_socket);        
                close $child;

                my $tout        = $CHILDIDLE;
                my $maintenance = 0;
                my $sig_set;
                my $old_sigset;

                while(1)
                {
                    if($maintenance >= $MAINTENANCE_LEVEL)
                    {
                        $maintenance = 0;
                        conf_check("child");
                    }

                    if($old_sigset)
                    {
                        unless (defined sigprocmask(SIG_UNBLOCK, $old_sigset))
                        {
                            mylog(warning=>'child: Could not unblock SIGHUP');
                        }
                    }

                    my $time_s          = time;
                    ($new_tcp_readable) = 
                     IO::Select->select($readable_handles, undef, undef, $tout);
                    my $time_e          = time;

                    # block SIGHUPs
                    $sigset     = POSIX::SigSet->new(SIGCHLD);
                    $old_sigset = POSIX::SigSet->new;

                    unless (defined sigprocmask(SIG_BLOCK, $sigset, $old_sigset))
                    {
                        mylog(warning=>'child: Could not block SIGHUP');
                    }

                    
                    $select_to = 1;
                    my $ans;
                    foreach my $sock (@$new_tcp_readable)
                    {
                        $select_to = 0;
                        my $ans;            # define for the "for"-scope
                        if($sock == $tcp_socket)
                        {
                            my $new_sock = $tcp_socket->accept();

                            if(!($new_sock) || (!($new_sock->connected)))
                            {
                                $tout = $CHILDIDLE - ($time_e - $time_s);
                                
                                if( ($tout <= 0) || ($tout > $CHILDIDLE))
                                {
                                    $tout = $CHILDIDLE;
                                }
                                next;
                            }
                            else
                            {
                                print $parent ("$$ 0\n");
                                $parent->recv($ans, 1024);
                                $tout    = $CHILDIDLE;
                                $new_sock->autoflush(1);

                                # set nonblocking IO, required by linux
                                # BSD did fine without
                                fcntl($new_sock, F_SETFD, O_NONBLOCK) || die $!;

                                $readable_handles->add($new_sock);
                            }
                            print $parent ("$$ 0\n");
                            $parent->recv($ans, 1024);
                        }
                        else
                        {
                            print $parent ("$$ 0\n");
                            $parent->recv($ans, 1024);
                            my $action;
                            my $buf;
                            my $ans;
                            my $busy;
                            $sock->timeout(1);

                            while(<$sock>)
                            {
                                $buf = $_;
                                if($buf)
                                {
                                    $busy   = 1;
                                    $action = parse_input($buf);
                                }

                                if($action eq 'EPARSE')
                                {
                                    $action = '';
                                    $buf = '';
                                    last;
                                }
                                if($action)
                                {
                                    $sock->send($action);
                                    
                                    if($TRY_BALANCE)
                                    {
                                        $readable_handles->remove($sock);
                                        $sock->close();
                                    }
                                    
                                    %attr = ();
                                    print $parent ("$$ 1\n");
                                    $parent->recv($ans, 1024);
                                    ++$maintenance;
                                    last;
                                }
                            }

                            next if ($buf && (!($action)));

                            if(!($buf))
                            {
                                $readable_handles->remove($sock);
                                $sock->shutdown(2);
                                close $sock;
                                print $parent ("$$ 1\n");
                                $parent->recv($ans, 1024);
                            }
                        }
                    }
                    if($select_to)
                    {
                        # child was idle too much, exit if no connection
                        # to a smtp
                        print $parent ("$$ 0\n");
                        $parent->recv($ans, 1024);
                        my $connected;

                        for($readable_handles->handles)
                        {
                            next if $_ == $tcp_socket or $_ == $parent;
                            $connected = 1;
                        }

                        if((!($connected)))
                        {
                            #ask dad if we can die
                            print $parent ("$$ d\n");
                            $parent->recv($ans, 1024);

                            if(($ans) && ($ans eq "y\n"))
                            {
                                mylog(info=>"child: exiting: idle for $CHILDIDLE sec.");
                                exit;
                            }
                        }

                        $readable_handles->add($tcp_socket);
                        print $parent ("$$ 1\n");
                        $parent->recv($ans, 1024);
                        $tout = $CHILDIDLE;
                    }
                 }
            }

#######################################################################
#
# PARENT again
#
            else
            {
                # piped control-communication with our children
                my $buf = <$sock>;
                if(!($buf)) 
                { 
                    $readable_handles->remove($sock); 
                    $sock->close; 
                    next
                }
                my ($cpid, $stat) = split(' ', $buf);
                # a kid ask to go suicide
                if($stat eq 'd')
                {
                    if(keys (%childs) > $MIN_PROC)
                    {
                        # tell kid to commit suicide
                        print $sock ("y\n");
                        delete $childs{$cpid};
                        delete $avail{$cpid};
                        $readable_handles->add($tcp_socket);
                    }
                    else
                    {
                        print $sock ("n\n");
                    }
                    next;
                }

                # a kid tells us whether it's busy or free
                if($stat == 1)
                {
                    $avail{$cpid} = 1;
                }
                else
                {
                    delete $avail{$cpid};
                }
                if(keys(%avail) > 0)
                {
                    $readable_handles->remove($tcp_socket);
                }
                elsif(keys(%childs) < $MAX_PROC)
                {
                    $readable_handles->add($tcp_socket);
                }
                print $sock ("1\n");
                next;
            }
        }
    }
}

sub parse_input
{
    $_ = shift; 
    $_ =~ tr/\r\n//d;

    if (/=/) 
    {
        my ($k, $v) = split (/=/, lc($_), 2); 
        $attr{$k}   = $v; 
        return;
    }
    elsif (length)
    {
        mylog(warning=>sprintf("ignoring garbage: %.100s", $_));
        return;

    }
    if ($VERBOSE == 1)
    {
        for (sort keys %attr)
        {
            mylog(debug=> "Attribute: $_=".$attr{$_});
        }
    }

    if(!($DAEMONIZE))
    {
        fatal_exit ("unrecognized request type: '$attr{request}'")
        unless 
        $attr{request} eq 'smtpd_access_policy';
    }
    else
    {
        if(!($attr{request} eq 'smtpd_access_policy'))
        {
            mylog(warning=>"unrecognized request type: '$attr{request}'");
            return('EPARSE');
        }
    }

    # If not daemonised, attr{things} may not be defined.
    if(!($DAEMONIZE)) { 
        if(!($attr{instance})) {
            $attr{instance} = 'default';
        }
        if(!($attr{client_name})) {
            $attr{client_name} = 'default';
        }
        if(!($attr{recipient})) {
            $attr{recipient} = 'default';
        }
    }

    my $response;
    my $action;
       $action   = $DEFAULT_RESPONSE;
    
    no strict 'refs';

    my $delay_time = time;
    $response = weighted_check->(attr=>\%attr);
    
    if ($response) 
    {
        $action = $response;
    }
    else
    {
        mylog(warning=>'weighted_check returned a zero value!');
    }

    # return only a restriction class if the user requested it with
    # specifying a response message with "rc:foo"
    if(index($action, 'rc:') != -1)
    {
        $action =~ s/^[ \t]*rc:[ \t]*(.*?)[,; .]+.*/$1/i;
    }

    my $trace_info = '';
    if($DEBUG)
    {
        $trace_info = '<instance='.$attr{instance}.'> ';
    }
    $trace_info  .= '<client=' . $attr{client_name} . '[' .
                    $attr{client_address}              .']> '  .
                    '<helo='   . $attr{helo_name}      . '> '  .
                    '<from='   . $attr{sender}         . '> '  .
                    '<to='     . $attr{recipient}      . '>'   ;


    mylog(info=>"decided action=$action; $trace_info; delay: ".
                (time - $delay_time).'s');
    return("action=$action\n\n");
}


sub address_stripped 
{
    # my $foo = localpart_lhs('foo+bar@baz.com'); # returns 'foo@baz.com'
    my $string = shift;
    
    for ($string) 
    {
        s/[+-].*\@/\@/;
    }
    return $string;
}




###############################################################################
###############################################################################
## subroutines ################################################################


#------------------------------------------------------------------------------
#        Plugin: weighted_check
#------------------------------------------------------------------------------
sub weighted_check
{
    local %_        = @_;
    my %attr        = %{ $_{attr} };

    my $ip          = $attr{client_address};
    $ip = Net::IP::ip_expand_address($ip,6) if Net::IP::ip_is_ipv6($ip);
    
    my $cl_hostname = $attr{client_name};

    my $cansw;

    my $client_name = $attr{client_name}              || '';
    my $helo        = $attr{helo_name}                || '';
    my $from        = address_stripped($attr{sender}) || '';
    my $rcpt        = $attr{recipient}                || '';

    my $instance    = $attr{instance} . $ip . $from;


    my $trace_info;
    if($DEBUG)
    {
        $trace_info = '<instance='.$instance.'> ';
    }
    $trace_info  .= "<client=$client_name\[$ip\]> <helo=$helo> <from=$from> <to=$rcpt>";



    my $from_domain;
    if($attr{sender} =~ /.*@(.*)/)
    {
        $from_domain = $1;
    }
    if($from eq '')
    {
        return('DUNNO NULL (<>) Sender');
    }
    my $orig_from   = $from;

    if($attr{recipient} && $attr{recipient} =~ /^(postmaster|abuse)\@/)
    {
        return('DUNNO mail for '.$attr{recipient});
    }

    if(($instance) && ($instance eq $accepted))
    {
        return ('DUNNO multirecipient-mail - already accepted by previous query');
    }
    elsif(($instance) && ($instance eq $blocked))
    {
        return ($my_REJECTMSG.' (multirecipient mail)' );
    }

## cache check
    if( ($CACHESIZE > 0) || ($POSCACHESIZE > 0) )
    {
        $cansw = cache_query('ask', $ip, '0', $orig_from, $from_domain);
    }


    if($cansw && index($cansw, 'rate') != 0)
    {
        $blocked      = $instance;
        $my_REJECTMSG = $cansw;

        return($my_REJECTMSG);
    }
    elsif($cansw && index($cansw, 'rate:hard:') == 0)
    {
        $accepted = $instance;
        return("$RETANSW $POSCACHEMSG; $cansw");
    }

## startup checks and preparing ###############################################

    my ($revip, $subip16, $subip);
    if (Net::IP::ip_is_ipv4($ip)) 
    {
        my ($ipp1, $ipp2, $ipp3, $ipp4) = split(/\./, $ip);
        $revip       = $ipp4.'.'.$ipp3.'.'.$ipp2.'.'.$ipp1;
        $subip16     = $ipp1.'.'.$ipp2.'.';
        $subip       = $subip16.$ipp3.'.';
    }
    else {
        $ip          = Net::IP::ip_expand_address($ip,6);
        $revip       = Net::IP::ip_reverse($ip);
        $revip       =~s/\.ip6.arpa\.$//;
        $subip16     = substr($ip,0,15);
        $subip       = substr($ip,0,20);
    }
   

    my $rate                    = 0;
    my $total_dnsbl_score       = 0; # this var holds only positive scores!
    my $helo_ok                 = 0;
    my $mx_ok                   = 0;
    my $helo_untrusted_ok       = 0;
    my $client_in_from          = 0;
    my $RET                     = '';
    my $dont_cache              = 0;
    my $do_client_from_check    = 0;
    my $client_seems_dialup     = 0;
    my $in_dyn_bl               = 0;
    my $helo_seems_dialup       = 0;
    my $rhsbl_penalty           = 0;
    my $bogus_mx_penalty        = 0;
    my $maxdnserr               = $MAXDNSERR;

    my $RELAYMSG                = '';

    my $found;
    
    my $rtime                   = time; # timestamp of policy request

## DNSBL check ################################################################
    my $i;
    my $dnsbl_hits = 0;
    
    $skip_rel  = $BL_SKIP_RELEASE + $BL_ERROR_SKIP;

    for($i=0;$i < @dnsbl_score; $i += 4)
    {
        $found = 0;
        my $answ = 0;
        
        if( (!($bl_err{$dnsbl_score[$i]}))                || 
            $bl_err{$dnsbl_score[$i]} <= $BL_ERROR_SKIP 
          )
        {
            $answ = rbl_lookup($revip.'.'.$dnsbl_score[$i]);
        }
        else
        {
            $RET .= ' '.$dnsbl_score[$i+3].'=SKIP('.$dnsbl_score[$i+2].')';
            $rate += $dnsbl_score[$i+2];

            if(++$bl_err{$dnsbl_score[$i]} >= $skip_rel)
            {
                $bl_err{$dnsbl_score[$i]} = 0;
            }
            next;
        }

        if(!($answ))
        {
            # increase err counter for that rbl
            ++$bl_err{$dnsbl_score[$i]};

            if($maxdnserr-- <= 1)
            {
                $accepted = $instance;
                return "$RETANSW $MAXDNSERRMSG in ".$dnsbl_score[$i].' lookups';
            }
            $RET .= ' '.$dnsbl_score[$i+3].'=ERR('.$dnsbl_score[$i+2].')';
            $rate += $dnsbl_score[$i+2];
            
            next;
        }

        $bl_err{$dnsbl_score[$i]} = 0;
        if($answ > 0)
        {
            $RET               .= ' IN_'.$dnsbl_score[$i+3].'=' .
                                         $dnsbl_score[$i+1];
            $found              = 1;
            $rate              += $dnsbl_score[$i+1];
            $total_dnsbl_score += $dnsbl_score[$i+1];

            if(index(lc($dnsbl_score[$i+3]), 'dyn') != -1)
            {
                $client_seems_dialup = 1;
                $in_dyn_bl = 1;
            }
        }

        if($found == 0)
        {
            if($LOG_BAD_RBL_ONLY == 1)
            {
                if($dnsbl_score[$i+2] != 0) # if an RBL entry manipulates
                                            # the overall score, log it though.
                {
                    $RET .= ' NOT_IN_'.$dnsbl_score[$i+3].'=' .
                                       $dnsbl_score[$i+2];
                }
            }
            else
            {
                $RET .= ' NOT_IN_'.$dnsbl_score[$i+3].'='.$dnsbl_score[$i+2];
            }
            $rate += $dnsbl_score[$i+2];
        }
        else
        {
            # increase DNSBL hitcounter only if the DNSBL is a RBL and no
            # DNS whitelist
            if($dnsbl_score[$i+1] > 0)
            {
                ++$dnsbl_hits;
            }
            else
            {
                next;
            }


            # check for DNSBL Hit/Score limit exceeding
            if( 
                ($dnsbl_hits      > $MAXDNSBLHITS ) ||
                ($total_dnsbl_score > $MAXDNSBLSCORE)
              )
            {
                if($CACHESIZE > 0 && $MAXDNSBLMSG !~ /^\s*(4|DEFER|rc\:)/i)
                {
                    cache_query('nadd', $ip, $total_dnsbl_score);
                }
                $blocked = $instance;
                mylog(info=>"weighted check: $RET; $trace_info; rate: $rate");
                return($MAXDNSBLMSG."; check http://www.robtex.com/rbl/$ip.html");
            }
        }
    }

    if($dnsbl_checks_only == 1)
    {
        return("$RETANSW $RET (only DNSBL check requested)");
    }
    my $re_count;
    for(@dnsbl_checks_only_regexps)
    {
        my $re = $_;
        $re_count++;
        next if not $re;
        if($cl_hostname && $cl_hostname =~ /$re/)
        {
            return("$RETANSW $RET (only DNSBL check requested (regex-nr: $re_count))");
        }
    }


## postive cache check
    if($cansw && ($POSCACHESIZE > 0) && ($dnsbl_hits < 1))
    {
            $accepted = $instance;
            return("$RETANSW $POSCACHEMSG; $cansw");
    }


## HELO/FROM DNS checks #######################################################
    $found = 0;
    my $is_mx            = 0;
    my $ip_eq_from       = 0;
    my $addresses        = '';
    my $mx_names         = '';
    my $recs_found       = 0;
    my $MATCH_TYPE;
    my $from_addresses   = '';

    my $dnserr           = 0;
    my $bogus_mx         = 0;
    my $bad_mx           = 0;
    my $bad_mx_scored    = 0;
    my $do_reverse_check = 0;

    my $squared_helo = squared_helo(\$helo, \$ip);
    if($squared_helo == 1) { $helo_ok = 1; }

    my $tmp_domain = $from_domain;
       $tmp_domain =~ s/[\[\]]//g;
       $tmp_domain = '['.$from_domain.']';
    my $tmpip = squared_helo(\$tmp_domain, \$ip);
    if($tmpip == 1)
    {
        $from_addresses .= " $from_domain";
        $found = 1; $helo_ok = 1;
    }
    $addresses .= " $helo";

    my @helo_parts = split(/\./,$helo);

    $from =~ /.*@(.*)/;
    my $tmp_from = $1;

    my @parts_check = ($tmp_from, $helo);    # don't change order

    for(my $tmpcnt=0; $tmpcnt < @parts_check; $tmpcnt++)
    {
        if($tmpcnt == 1)
        { 
            $MATCH_TYPE = 'HELO'; 
        } 
        else 
        { 
            $MATCH_TYPE = 'FROM';
        }

        my @parts = split(/\./,$parts_check[$tmpcnt]);

        for(;@parts >=2;shift(@parts))
        {
            my $testhelo = join('.',@parts);
            next if $testhelo =~ /\[|\]/;
            my $query    = $res->send($testhelo, 'MX');

            if(dns_error(\$query, \$res))
            {
                if($maxdnserr-- <= 1)
                {
                    $accepted = $instance;
                    return("$RETANSW $MAXDNSERRMSG in $MATCH_TYPE MX lookups for $testhelo");
                }
                next;

            }

            # removed "if($query && $query->answer)" (which was introduced in
            # 0.1.14.4 due to dns_error() implementation) in 0.1.14.5 because
            # A lookups were not performed if MX returned NXDOMAIN
            # XXX: this is to be reviewed and sanitized
            if($query)
            {
                $recs_found = 1; # means, we've got some dns response

                foreach my $rr ($query->answer)
                {
                    if($rr->type eq 'MX')
                    {
                        for my $query_type ('A','AAAA')
                        {

                            my $mxres  = $res->send($rr->exchange , $query_type);

                            if(dns_error(\$mxres, \$res))
                            {
                                if($maxdnserr-- <= 1)
                                {
                                    $accepted = $instance;
                                    return("$RETANSW $MAXDNSERRMSG in $MATCH_TYPE MX -> A lookups");
                                }
                                next;
                            }
                            foreach my $mxvar ($mxres->answer)
                            {
                                next if ($mxvar->type ne 'A' && $mxvar->type ne 'AAAA');
                                my $ip_address = $mxvar->address;
                                $ip_address = Net::IP::ip_expand_address($mxvar->address,6) 
                                    if Net::IP::ip_is_ipv6($mxvar->address);
                            
                                # store sender MX hostname entries for comparission 
                                # with HELO argument
                                if ($MATCH_TYPE eq 'FROM')
                                {
                                    $mx_names .= '.'.$rr->exchange . " ";
                                }
                            
                                if($tmpcnt == 0)
                                {
                                    $from_addresses .= ' '.$ip_address;
                                }

                                $addresses .= ' '.$ip_address;

                                if ($ip eq $ip_address)
                                {
                                    $RET    .= ' CL_IP_EQ_'.$MATCH_TYPE.'_MX=' .
                                           $helo_from_mx_eq_ip_score[1];

                                    $found   = 1;
                                    $is_mx   = 1 if $MATCH_TYPE eq 'FROM';
                                    $helo_ok = 1;
                                    $mx_ok   = 1;
                                    $rate   += $helo_from_mx_eq_ip_score[1];
                                    last;
                                }
                                undef $ip_address;
                            }

                        }  #Ipv4/IPv6
                    }
                    last if $found;
                }

                # penalize dnsbl-weighted for empty/bogus MX records
                # XXX: probably need to separate hostnames from domainnames
                if( $MATCH_TYPE eq 'FROM'    &&
                    (!($bad_mx))             && 
                    (
                     $from_addresses !~ /\d+/ ||
                     $from_addresses =~ 
                 /( 127\.| 192\.168\.| 10\.| 172\.(?:1[6-9]|2\d|3[01])\.)/
                    )
                  )
                {
                    $bad_mx = 1;
                }


                if(!($found))
                {
                    
                    for my $query_type ('A','AAAA')
                    {

                        my $query = $res->send($testhelo,$query_type);  
                        
                        if(dns_error(\$query, \$res))
                        {
                            if($maxdnserr-- <= 1)
                            {
                                $accepted = $instance;
                                return("$RETANSW $MAXDNSERRMSG in $MATCH_TYPE A lookup for $testhelo");
                            }
                            next;
                        }

                        foreach my $addr ($query->answer)
                        {
                            if($addr->type eq 'PTR')
                            {
                                if($helo == $ip)
                                {
                                    $RET              .= ' CL_IP_EQ_HELO_NUMERIC='.
                                                         $helo_score[1];

                                    $rate             += $helo_score[1];
                                    $found             = 1;
                                    $helo_untrusted_ok = 1;
                                }
                            }

                            if(($addr->type ne 'A' && $addr->type ne 'AAAA')){ next; }
                            
                            my $ip_address = $addr->address;
            
                            $ip_address= Net::IP::ip_expand_address($addr->address,6)
                                if Net::IP::ip_is_ipv6($addr->address);
                        
                            if($tmpcnt == 0)
                            {
                                $from_addresses .= ' '.$ip_address;
                            }

                            $addresses .= ' '.$ip_address;
                        
                            if ($ip eq $ip_address)
                            {
                                $found    = 1;
                                $helo_ok  = 1;
                                $RET     .= ' CL_IP_EQ_'.$MATCH_TYPE.'_IP=' .
                                            $helo_score[1];
                            
                                $rate    += $helo_score[1];
                                $bad_mx   = 0;
                        
                                if($tmpcnt == 0)
                                {
                                    $ip_eq_from = 1;
                                }
                        
                                last;
                            }
                            undef $ip_address;
                        }
                    } #IPv4/IPv6
                }

                if($bad_mx && (!($bad_mx_scored)))
                {
                    my $score = $bogus_mx_score[0] * $total_dnsbl_score;
                    if($score)
                    {
                        $RET             .= ' BAD_MX='.$score;
                        $rate            += $score;
                        $bad_mx_scored    = 1;
                    }

                }

                # check if sender domain has bogus or empty
                # A/MX records.
                if( ($MATCH_TYPE eq 'FROM')   &&
                    (!($bogus_mx))            &&
                    (
                     $from_addresses !~ /\d+/ || 
                     $from_addresses =~
                 /( 127\.| 192\.168\.| 10\.| 172\.(?:1[6-9]|2\d|3[01])\.)/
                    )
                  )
                {
                    my $score = $bogus_mx_score[0] + $total_dnsbl_score;
                    $RET             .= ' BOGUS_MX='.$score;
                    $rate            += $score;
                    $bogus_mx         = 1;
                    $bogus_mx_penalty = $score;
                }

                
                last if $found;
            }
            last if $found;
        }
        last if $found;
    }
    if((!($found)) && $recs_found) # helo seems forged
    {
        if(index($addresses,' '.$subip) != -1)
        {
            $RET     .= ' HELO_IP_IN_CL_SUBNET='.$helo_ip_in_client_subnet[1];
            $rate    += $helo_ip_in_client_subnet[1];
            $helo_ok  = 1;
            $found    = 1;
        }
        elsif(index($addresses,' '.$subip16) != -1)
        {
            $RET               .= ' HELO_IP_IN_CL16_SUBNET=' .
                                  $helo_ip_in_cl16_subnet[1];

            $rate              += $helo_ip_in_cl16_subnet[1];
            $helo_untrusted_ok  = 1;
            $do_reverse_check   = 1;
            $found              = 1;
        }
        if($found != 1 && $helo_ok != 1 && $squared_helo != 1)
        {
         my $score    = $helo_score[0] + $total_dnsbl_score;
            $RET     .= ' CL_IP_NE_HELO='.$score;
            $helo_ok  = 2;
            $rate    += $score;
        }
    }
    elsif($found != 1) # probably DNS error
    {
     my $score    = ($helo_score[0]-0.1);
        $RET     .= ' NO_MX_A_RECS_FOUND='.$score;
        $rate    += $score;
        $helo_ok  = 2;
    }




## HELO numeric check #########################################################
    my $glob_numeric_score;
    # check /1.2.3.4/ and /[1.2.3.4]/
    if($helo =~ /^[\d|\[][\d\.]+[\d|\]]$/)
    {
        $glob_numeric_score = myrnd (
            $helo_numeric_score[0] + 
            ($helo_numeric_score[0] * $total_dnsbl_score)
        );
        $RET  .= ' HELO_NUMERIC='.$glob_numeric_score;
        $rate += $glob_numeric_score;
    }






## FROM Domain vs HELO regex check ############################################
    if(!($is_mx))
    {
        $from       =~ s/.*@//;                 # delete localpart
        my $tmphelo = $helo;
        my $tmp_helo_domain;    


        # handle sender "(host.)sub.domain.co.uk"
        # keep:  "domain"
        if   ($from =~ s/\.[a-z]{2}\.[a-z]{2}$//i)              
        { $from =~ s/.*\.// }
        
        # handle sender "(host.)sub.domain1.com.br"
        # keep:  "domain"
        elsif($from =~ s/\.(com|org|net)\.[a-z]{2}$//i) 
        { $from =~ s/.*\.// }
        
        # handle sender "(host.)sub.domain.com"
        # handle "(host.)sub.domain.de"
        # keep:  "domain"
        elsif($from =~ s/\.[a-z]{2,5}$//i) 
        { $from =~ s/.*\.// }

        # handle helo "(host.)sub.domain.co.uk"
        if   ($tmphelo =~ s/\.[a-z]{2}\.[a-z]{2}$//i) 
        { }

        # handle helo "(host.)sub.domain1.com.br"
        elsif($tmphelo =~ s/\.(com|org|net)\.[a-z]{2}$//i)
        { }

        # handle helo "(host.)sub.domain.com"
        # handle helo "(host.)sub.domain.de"
        # keep:  "domain"
        elsif($tmphelo =~ s/\.[a-z]{2,5}$//i)
        { }

        # get helo domain for checking against sender MX entries
        $tmp_helo_domain  =  $tmphelo;
        $tmp_helo_domain  =~ s/.*\.//; 

        # set "." (dot) delimiter for comparisions
        $from            = '.' . $from            .'.';
        $tmphelo         = '.' . $tmphelo         .'.'; 
        $tmp_helo_domain = '.' . $tmp_helo_domain .'.';
        
        $RET .= ' (check from: '   . $from 
             .  ' - helo: '        . $tmphelo 
             .  ' - helo-domain: ' . $tmp_helo_domain .') ';

        # check trusted helos
        if($helo_ok == 1)
        {
            if(
                (index($tmphelo,$from)             != -1)  ||
                (index($from,$tmphelo)             != -1)  ||
                (index($mx_names,$tmp_helo_domain) != -1)  ||
                (index($from_addresses,$ip)        != -1)
              )
            {
                $RET  .= ' FROM/MX_MATCHES_HELO(DOMAIN)=' .
                         $from_match_regex_verified_helo[1];

                $rate += $from_match_regex_verified_helo[1];
            }
            else
            {
             my $score = myrnd( 
                            (   $from_match_regex_verified_helo[0] 
                              + ($total_dnsbl_score/4)
                              + ($bogus_mx_penalty * $bogus_mx_penalty)
                              + $glob_numeric_score
                            )
                         );
                $RET  .= ' FROM/MX_MATCHES_NOT_HELO(DOMAIN)='.$score;
                $rate += $score;
                $do_client_from_check = 1;
            }
        }


        elsif(index($client_name,$from) != -1 && $squared_helo != 1)
        {
            $RET  .= ' CL_HOSTNAME_MATCHES_FROM(DOMAIN)=' .
                $helo_ip_in_client_subnet[1];
            $rate += $helo_ip_in_client_subnet[1];
            $helo_ok              = 1;
            $do_reverse_check     = 0;
            $do_client_from_check = 0;
            $helo_untrusted_ok    = 0;
        }


        elsif($helo_untrusted_ok == 1 && $squared_helo != 1)
        {
            # check untrusted helos
            if( (index($tmphelo,$from)             != -1)  ||
                (index($from,$tmphelo)             != -1)  ||
                (index($mx_names,$tmp_helo_domain) != -1)  ||
                (index($client_name,$from)         != -1)
              )
            {
                $RET  .= ' FROM/MX_MATCHES_UNVR_HELO(DOMAIN)_OR_CL_NAME(DOMAIN)=' .
                         $from_match_regex_unverified_helo[1];

                $rate += $from_match_regex_unverified_helo[1];
            }
            else
            {
             my $score = (   $from_match_regex_unverified_helo[0] 
                           + $total_dnsbl_score
                           + ($bogus_mx_penalty * $bogus_mx_penalty)
                         );

                $RET  .= ' FROM/MX_MATCHES_NOT_UNVR_HELO(DOMAIN)_NOR_CL_NAME(DOMAIN)='.$score;
                $rate += $score;
            
                $do_client_from_check = 1;
            }
        }

        # check totaly failed helos
        elsif(index($tmphelo,$from) != -1 || index($from,$tmphelo) != -1)
        {
            $RET  .= ' MAIL_SEEMS_FORGED='.$from_match_regex_failed_helo[0];
            $rate += $from_match_regex_failed_helo[0];
        }

        elsif(index($tmphelo,$from) == -1 || index($from,$tmphelo) == -1)
        {
         my $score = (  $from_match_regex_failed_helo[0] 
                      + 0.5 
                      + $total_dnsbl_score
                     );
            $RET  .= ' FROM_NOT_FAILED_HELO(DOMAIN)='.$score;
            $rate += $score;
        }
    }


## Reverse IP == dynhost check ###############################################

    my $ip_res = $res->send("$ip");
    my @reverse_ips;

    if($ip_res && $ip_res->answer)
    {
        foreach my $tmprr ($ip_res->answer)
        {
            if($tmprr->type eq 'PTR')
            {
                my $tmpptr =  $tmprr->ptrdname;
                   $tmpptr =~ s/\.$//;
                push(@reverse_ips, lc($tmpptr));
            }
        }
    }

    if((!($client_seems_dialup)) && ($mx_ok != 1))
    {
        foreach my $revhost (@reverse_ips)
        {
            if( $revhost =~ /(mx|smtp|mail|dedicated|(\b|[^n])stat).*?\..*?\./i )
            { last }

            if (
                $revhost =~ 
          /(\.dip|cable|ppp|dial|dsl|dyn|client|rev.*?(ip|home)).*?\..*?\./i
               ||
               $helo    =~ 
                  /[a-z\.\-\_]+\d{1,3}[-._]\d{1,3}[-._]\d{1,3}[-._]\d{1,3}/i
               )
            {
                $client_seems_dialup = 1;
                $total_dnsbl_score  += $client_seems_dialup_score[0];
                $rate               += $client_seems_dialup_score[0];
                $RET                .= ' CL_SEEMS_DIALUP=' .
                                       $client_seems_dialup_score[0]; 
                last;
            }
        }
    }

## GeoIP check 
    if($geoip_scoring_enabled == 1) {
        our $geoip = Geo::IP->new(GEOIP_STANDARD);
        my $country = $geoip->country_code_by_addr("$ip");
        if(defined($country)) 
        {
            for($i=0; $i<@geoip_score; $i+= 4)
            {
                if($country eq $geoip_score[$i]) 
                {
                    my $score = $geoip_score[$i+2];
                    if($score != 0) {
                        $RET .= " IN_" . $geoip_score[$i+3] . "=" . $score;
                        $rate += $score;
                    }
                }
                else {
                    my $score = $geoip_score[$i+1];
                    if($score != 0) {
                        $RET .= "NOT_IN_" . $geoip_score[$i+3] . "=" . $score;
                        $rate += $score;
                    }
                }
            }
            $RET .= " (GeoIP lookup: $country)";
        }
    }
 
## Reverse IP == HELO check ###################################################
    $found = 0;
    my $rev_processed = 0;

    if(($helo_ok != 1 && $helo_untrusted_ok != 1) || $do_reverse_check)
    {
        foreach my $revhost (@reverse_ips)
        {
            $rev_processed = 1;
            $revhost       =~ s/\.*$//;

            if ( $revhost eq $helo )
            {
                $found = 1;
                $RET  .= ' REV_IP_EQ_HELO='.$client_ip_eq_helo_score[1];
                $rate += $client_ip_eq_helo_score[1];
                last;
            }

            my $partsfound = 0;
            my $tmprevhost = reverse($revhost);
            my $tmphelo    = reverse($helo);
               $tmphelo    =~ s/.*?\.([^.]+).*/$1/;

            if( ($tmprevhost =~ /\.\Q$tmphelo\E$/i ) ||
                ($tmprevhost =~ /\.\Q$tmphelo\E\./i)
              )
            {
                $partsfound  = 1;
            }

            if( $partsfound != 1 )
            {
                my $tmphelo    = reverse($helo);
                   $tmprevhost =~ s/.*?\.([^.]+).*/$1/;

                if( ($tmphelo  =~ /\.\Q$tmprevhost\E$/i ) ||
                    ($tmphelo  =~ /\.\Q$tmprevhost\E\./i)
                  )
                {
                    $partsfound = 1;
                }
            }

            if($partsfound == 1)
            {
                $found = 1;
                $RET  .= ' REV_IP_EQ_HELO_DOMAIN='.$client_ip_eq_helo_score[1];
                $rate += $client_ip_eq_helo_score[1];
                last;
            }
        }

        if($rev_processed != 1 && $recs_found != 1)
        {
            $RET   .= ' NO_DNS_RECORDS=0.5';
            $rate  += 0.5;
            $dnserr = 1;
        }

        if($found != 1 && $squared_helo != 1)
        {
            $RET  .= ' RESOLVED_IP_IS_NOT_HELO='.$client_ip_eq_helo_score[0];
            $rate += $client_ip_eq_helo_score[0];
        }
        else
        {
            if( ! ($cl_hostname && $cl_hostname ne "unknown") )
            {
                $helo_untrusted_ok = 1;
            }
            else
            {
                $helo_untrusted_ok = 0;
            }
        }
    }


## HELO dialup check ##########################################################

    my $DYN_DNS_MSG = '';
    if(
        (   ($enforce_dyndns_score[0] != 0)  || 
            ($client_seems_dialup     != 1)
        ) 
        &&
        (!($mx_ok)) && (!($ip_eq_from))
        &&
        $helo !~ /(mx|smtp|mail|dedicated|(\b|[^n])stat).*?\..*?\./i
        &&
        (
            (
                $helo =~ 
           /(\.dip|cable|ppp|dial|dsl|dyn|client|rev.*?(ip|home)).*?\..*?\./i
            ) ||
            (
                $helo =~ /[a-z\.\-\_]+\d{1,3}[-._]\d{1,3}[-._]\d{1,3}[-._]\d{1,3}/i
                     # that's an ugly regex! watch this!
            )
        )
      )
    {
        $helo_seems_dialup = 1;

        $DYN_DNS_MSG = "; Please use DynDNS";

        if($helo_ok == 1)
        {
         my $score   = $helo_seems_dialup[0] + $enforce_dyndns_score[0];
            $RET    .= ' HELO_SEEMS_DIALUP='.$score;
            $rate   += $score;

        }
        else
        {
         my $score   = $failed_helo_seems_dialup[0] + $enforce_dyndns_score[0];
            $RET    .= ' NOK_HELO_SEEMS_DIALUP='.$score;
            $rate   += $score;
        }
    }


## From has nobody/anonymous user #############################################
    my $anon= 0;

    if($orig_from =~ /(nobody|anonymous)\@/)
    {
     my $score              = $from_anon[0] + $total_dnsbl_score + 
                              $glob_numeric_score;
        $RET               .= ' FROM_NBDY_ANON='.$score;

        $rate              += $score;
        $anon               = 1;
    }

## client == MX/A FROM domain #################################################
    
    if( 
        ($mx_ok != 1)               &&
        (
            ($do_client_from_check) &&
            ($dnsbl_hits > 0)
        )                           &&
        ( $squared_helo != 1)
      )
    {
        if( index($from_addresses, $ip) == -1 )
        {
         my $score = $helo_from_mx_eq_ip_score[0] + $total_dnsbl_score;

            $RELAYMSG = '; please relay via your ISP ('.$from_domain.')';

            $RET     .= ' CLIENT_NOT_MX/A_FROM_DOMAIN='.$score;

            $rate    += $score;

            if( index($from_addresses, $subip) == -1 )
            {
                $RET  .= ' CLIENT/24_NOT_MX/A_FROM_DOMAIN='.$score;

                $rate += $score;
            }
        }
    }

## From domain multiparted check ##############################################
    if( 
        (!($helo_ok || $mx_ok))        &&
        ($rate < $REJECTLEVEL)         && 
        ($orig_from =~ /\@.*?\..*?\./)
      )
    {
     my $score = $from_multiparted[0] + $total_dnsbl_score;
        $RET  .= ' FROM_MULTIPARTED='.$score;
        $rate += $score;
    }

## Random sender check ########################################################
    if( 
        ($rate < $REJECTLEVEL) &&
        (
            ($orig_from =~ /[bcdfgjklmnpqrtvwxz]{5,}.*\@/i) ||
            ($orig_from =~ /[aeiou]{4,}.*\@/i)
        )
      )
    {
     my $score = (   $total_dnsbl_score 
                   + ($total_dnsbl_score * $random_sender_score[0]) 
                   + $random_sender_score[0]
                 );
        $RET .=  ' RANDOM_SENDER=' . $score;
        $rate += $score;
        
        $rhsbl_penalty = $rhsbl_penalty_score[0] * $random_sender_score[0];
    }

## rhsbl check ################################################################
    my $in_rhsbl;
    my $RHSBLMSG = '';

    if($rate < $REJECTLEVEL)
    {
        $orig_from =~ /@(.*)/;
        my $query  =  $1;

        if(  ($do_client_from_check == 1)      ||
             ( 
               ($helo_untrusted_ok == 1) && 
               ($client_in_from    != 1)
             )                                 ||
             ($bogus_mx             == 1)
          )
        {
            $rhsbl_penalty += $rhsbl_penalty_score[0]; 
        }

        for($i=0;$i < @rhsbl_score; $i += 4)
        {
            my $answer = rbl_lookup($query.'.'.$rhsbl_score[$i], 'A');

            if(!($answer))
            {
                if($maxdnserr-- <= 1)
                {
                    $accepted = $instance;
                    return ("$RETANSW $MAXDNSERRMSG in " . 
                             $rhsbl_score[$i].' lookups');
                }
                next;
            }
            if($answer > 0)
            {
             my $score = myrnd( 
                            ($rhsbl_score[$i+1] + $rhsbl_penalty ) +
                            ($total_dnsbl_score/2)
                         );
                $RET      .= ' IN_'.$rhsbl_score[$i+3].'=' . $score;

                $rate      = myrnd($rate + $score);

                $RHSBLMSG .= '; in '.$rhsbl_score[$i];
            }
        }
    }


###############################################################################
# parse and store results, do some cleanup, return results

    # sanitize rate, perl gives inaccurate results in computings like
    # -4.6 + 4.3
    $rate = myrnd($rate);


    if(($DEBUG) || ($CMD_DEBUG == 1))
    {
        $addresses =~ s/ $//;
        $RET      .=  ' <helo_ips: '.$addresses.'>';
    }

    mylog(info=>"weighted check: $RET; $trace_info; rate: $rate");

    if(($dnserr == 1) && ($dnsbl_hits < 2))         # applies if not too
    {                                               # much dnsbl listed
        my $my_DNSERRMSG = $DNSERRMSG . ' Your HELO: '.$helo.', IP: '.$ip;
        return($my_DNSERRMSG);
    }

    if($rate >= $REJECTLEVEL)
    {
        $blocked = $instance;

        $my_REJECTMSG = $REJECTMSG;  
                                 
        $dont_cache = 0;

        if($rate < $DEFER_LEVEL)
        {
            my @defer_arr = split(' ', $DEFER_STRING);

            foreach(@defer_arr)
            {
                if(index($RET, ' '.$_) != -1)
                {
                    $dont_cache   = 1;
                    $my_REJECTMSG =~ s/^.*? /$DEFER_ACTION /;
                    last;
                }
            }
        }
        if($my_REJECTMSG =~ /^(4|DEFER|rc\:)/i)
        {
            $dont_cache = 1;
        }
        if(($CACHESIZE > 0) && ($maxdnserr > 0) && (!($dont_cache)))
        {
            # add only the IP to SPAM cache if the client is dnsbl listed,
            # a dynamic client or has no ok helo
            # This should help in case of some dictionary attacks
            if(($dnsbl_hits >= 1 || $client_seems_dialup || $helo_ok != 1))
            {
                cache_query('nadd', $ip, $rate);
            }
            else
            { 
                cache_query('nadd', $ip, $rate, $orig_from, $from_domain);
            }
        }

        if(($helo_ok != 1) && ($helo_untrusted_ok != 1))
        {
            my $EREJECTMSG = $my_REJECTMSG .
                             '; MTA helo: '.$helo.', MTA hostname: ' .
                             $client_name.'['.$ip.'] (helo/hostname mismatch)';

            return($EREJECTMSG.$RHSBLMSG.$RELAYMSG.$DYN_DNS_MSG);
        }
        return($my_REJECTMSG.$RHSBLMSG.$RELAYMSG.$DYN_DNS_MSG);
    }
    else
    {
        if(($POSCACHESIZE > 0) && ($dnsbl_hits < 1))
        {
            cache_query('padd', $ip, $rate, $orig_from, $from_domain);
        }
        $accepted = $instance;
        return("$RETANSW $RET; rate: $rate");
    }
}




#
# cache_query (QUERY, IP, SENDER, [RATE], DOMAIN)
#
# Function for querying the cache daemon
#
# QUERY  : "nadd"  - negative (SPAM) add
#        : "padd"  - positive (HAM)  add
#        : "ask"  - is cached as SPAM or HAM?
#        : "kill"  - terminated cache
#        : "start" - pre-start cache
# IP     : Client IP
# SENDER : Sender Address
# RATE   : store rate in "Xadd" queries
# DOMAIN : Sender domain
#
# Returns: CACHEREJECTMSG when SPAM listed
#        : "rate: $rate"  when HAM  listed
#        : undef in all other cases
sub cache_query
{

    my $query  = shift(@_) || '';
    my $ip     = shift(@_) || '';
    my $rate   = shift(@_) || '';
    my $sender = shift(@_) || '';
    my $domain = shift(@_) || '';

    # Not sure why we're setting errno to 0 (or indeed the original '' which made perl moan).
    $! = 0;
    $@ = ();
    if( (!($csock)) || ($csock && (!($csock->connected))) )
    {
        $csock = IO::Socket::UNIX->new($SPATH);
        if( (!($csock = IO::Socket::UNIX->new($SPATH))) )
        {
            if($query ne 'start')
            {
                mylog(warning=>"cache_query: \$csock couln't be created: $@, calling spawn_cache()");
            }
            else
            {
                mylog(info=>'cache_query: start: calling spawn_cache()');
            }
            spawn_cache();
            return(undef);
        }
        if( $query eq 'start')
        {
            $csock->close(); # dont inherit this socket;
            return(undef);
        }
    }

    if($csock && ($csock->connected))
    {
        my $buf;

        my $alrm   = 0;
        
        $SIG{'ALRM'} = sub { 
            # ignore alarms;
            $alrm = 1; 
        };

        $csock->autoflush(1);
        mylog(info=>"cache_query: $query $ip $rate $sender $domain") if $DEBUG;
        print $csock "$CVERSION $query $ip $rate $sender $domain\n";
 
        my $sline;
        my $match = $query.$ip.$sender.' ';
        
        $csock->timeout($IPC_TIMEOUT);
        
        while($csock->connected)
        {
            eval
            {
                local $SIG{'ALRM'} = sub { 
                    mylog(warning=>'cache_query: timeout');
                    die "ETIMEOUT"; 
                };
                alarm $IPC_TIMEOUT;
                $csock->recv($buf, 4069);
                alarm 0;
            };

            if($@ || (!($buf))) { return(undef) };

            if($STATS)
            {
                $buf =~ s/^.*?(blocked|pass)/$1/;
                print $buf;
                return(undef) if $buf =~ /\nEOF\n/;
                next;
            }
            
            if($buf !~ /\n$/)
            {
                $sline .= $buf;
                next;
            }
            else
            {
                $sline .= $buf;
            }

            $sline =~ tr/\r\n//d;
            
            mylog(info=>"cache_query: \"$sline\" vs \"$match\"") if $DEBUG;

            if(index($sline, 'unknown cache request') >= 0)
            {
                print $csock "kill\n";
                close($csock);
                $csock = "";
                return(undef);
            }
            
            # return a proper line in case we had query timeouts
            # works like "next if not $sline =~ s/.*\Q$match\E//;" but faster
            my $index = rindex($sline, $match);
            next if $index < 0;
            return(substr($sline, $index + length($match)));
        }
        return(undef); # just in case ...
    }
    else
    {
        mylog(info=>'could not connect to cache (maybe just starting up)');
        return(undef);
    }
}



#############################################################################
#
# CACHE PROCESS
# 
#############################################################################
sub spawn_cache
{
    my $rname = getpwuid($<);

    if(($rname ne $USER) && (!($CMD_DEBUG)))
    {
        mylog(warning=>"cache: running as wrong user: ".$rname."; please edit master.cf, set user=$USER and/or add $USER to your user and group accounts; cache not spawned.");
        return(undef);
    }

    if(!( $< = getpwnam($USER)))
    { 
        mylog(warning=>"cache: couldn't change UID to user $USER: $!");
        die $!;
    }

    if(!( $( = getpwnam($USER) ))
    {
        mylog(warning=>"cache: couldn't change GID to user $GROUP: $!");
    }
    create_lockpath('cache');
 
    # avoid races at startups
    mkdir $LOCKPATH.'/cache_lock' or return undef;

    # check if a cache-socket file exist, and
    # whether we can connect to it.
    if( -S $SPATH)
    {
        my $test_sock = IO::Socket::UNIX->new($SPATH);
        if ($test_sock && $test_sock->connected)
        {
            mylog(warning=>"cache-init: error: socket exists and is connectable");
            return undef;
        }
        close($test_sock);
    }


    # no cache seems to exist, go create one
    mylog(debug=>'cache-init: no cache appears to exist; trying to create');

    unlink $SPATH;
    use POSIX qw(setsid);

    defined(my $pid = fork) or die "cache: fork: $!";
    if($pid)
    {
        return(undef);
    }

    setsid                  or die "cache: setsid: $!";

    $SIG{__DIE__} = sub {
        die @_ if index($_[0], 'ETIMEOUT') == 0;
        mylog(warning=>"cache: err: @_");
        unlink $SPATH;
        rmdir $LOCKPATH.'/cache_lock';
    };


    # change directory to $LOCKPATH in order to get some
    # coredumps just in case.

    # Ensure cache path exists. We don't particularly care if this fails to work, as the chdir should catch anything problematic
    eval {
        make_path("$LOCKPATH/cores/cache", { 'mode' => 0700 } );
    };
    # warn $@ if $@;
    chdir "$LOCKPATH/cores/cache" or die
        "cache: chdir $LOCKPATH/cores/cache: $!";


    mylog(info=>'cache spawned'); 
    $0 = 'policyd-weight (cache)';

    if($CMD_DEBUG != 1)
    {
        close(STDIN);
        close(STDOUT);
        close(STDERR);
        open (STDIN,  '/dev/null');
        open (STDOUT, '>/dev/null');
        open (STDERR, '>/dev/null');
    }

    $s = '' if $s;    # close socks, we don't need them anymore.
    $res = '' if $res;
    $sock->close if $sock;
    $new_sock->close if $new_sock;
    $tcp_socket->close if $tcp_socket;

    $SIG{'TERM'} = sub {
        unlink $SPATH;
        rmdir $LOCKPATH.'/cache_lock';
        mylog(info=>"cache: SIG@_, terminating");
        exit 0;
    };
    $SIG{'QUIT'} = sub {
        unlink $SPATH;
        rmdir $LOCKPATH.'/cache_lock';
        mylog(info=>"cache: SIG@_, terminating");
        exit 0;
    };


    $SIG{'INT'}   = sub { unlink $SPATH;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_, terminating"); exit};


    # commented because an interrupt of 'policyd-weight -s' may
    # cause a SIGPIPE
    # changed in: 0.1.14 beta-12
    #$SIG{'PIPE'}  = sub { unlink $SPATH;
    #                  rmdir $LOCKPATH.'/cache_lock';
    #                  mylog(warning=>"cache: SIG@_, terminating"); exit};
    
    $SIG{'PIPE'} = 'IGNORE';



    $SIG{'SYS'}   = sub { unlink $PIDFILE;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_, terminating"); exit}; 

    $SIG{'USR1'}  = sub { unlink $PIDFILE;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_, terminating"); exit};

    $SIG{'USR2'}  = sub { unlink $PIDFILE;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_, terminating"); exit};

    if($SIG{'POLL'})
    {
        $SIG{'POLL'}   = sub { unlink $PIDFILE;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_, terminating"); exit};
    }


    if($SIG{'UNUSED'})
    {
        $SIG{'UNUSED'} = sub { unlink $PIDFILE;
                      rmdir $LOCKPATH.'/cache_lock';
                     mylog(warning=>"cache: SIG@_, terminating"); exit};
    }


# core dumpers
    $SIG{'SEGV'}  = sub { 
                      $SIG{"ABRT"} = '';
    #                  cluck;
                      unlink $SPATH;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_:".longmess().
                        " terminating");
                      CORE::dump(); exit};

    $SIG{'ILL'}   = sub { 
                      $SIG{"ABRT"} = '';
                      unlink $SPATH;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_,".longmess().
                        " terminating"); 
                      CORE::dump(); exit};

    $SIG{'ABRT'}  = sub { 
                      unlink $SPATH;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_,".longmess().
                        " terminating"); 
                      CORE::dump(); exit};

    $SIG{'FPE'}   = sub { 
                      $SIG{"ABRT"} = '';
                      unlink $SPATH;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_,".longmess().
                        " terminating"); 
                      CORE::dump(); exit};

    $SIG{'BUS'}   = sub { 
                      $SIG{"ABRT"} = '';
                      unlink $SPATH;
                      rmdir $LOCKPATH.'/cache_lock';
                      mylog(warning=>"cache: SIG@_,".longmess().
                        " terminating"); 
                      CORE::dump(); exit};


    use strict;
    my $readable_handles = new IO::Select();

    umask(0007); # alow only owner and group to read/write from/to socket

    our $lsock = IO::Socket::UNIX->new( Listen => $SOMAXCONN,
                                        Local => $SPATH) or 
                                        die "warning: cache: $@ $!";

    rmdir $LOCKPATH.'/cache_lock';
    chown($<, $(, $SPATH); # set correct socket owner and group
    
    $readable_handles->add($lsock);

    $| = 1;
    my  $new_readable;
    my  $i;
    my  $KILL;
    our $poscache_cnt = 0;
    our $cache_cnt    = 0;
    our $maintenance  = 0;
    our $FORCE_MAINT;
    
    my  $old_mtime;
    if($conf ne 'default settings')
    {
        $old_mtime = (stat($conf))[9];
    }

    ptime_conv();

    while(1)
    {
        autoflush $lsock 1;
        $FORCE_MAINT = 1;
        ($new_readable) =
            IO::Select->select($readable_handles, undef, undef, $MAXIDLECACHE);

        foreach my $sock (@$new_readable)
        {
            $FORCE_MAINT = 0;

            if($sock == $lsock)
            {
                my $new_sock = $sock->accept();
                $new_sock->autoflush(1);
                $readable_handles->add($new_sock);
            }
            else
            {
                    $sock->autoflush(1);
                    my $buf = <$sock>;
                    if(($buf) && ($buf =~ /\n.*?\n/)) 
                        { mylog(info=>'cache: multiline request. Doh!'); }
                    $buf =~ tr/\r\n//d if $buf;

                    if($buf)
                    {
                        my $time = time;
                        my $ret  = '0'; # this var will hold the returned
                                        # result for the client if not told
                                        # within the routines

                        my($cv, $query, $ip, $rate, $sender, $domain) = 
                            split(/ /, lc($buf));
                        
                        if($CVERSION != $cv && (!($KILL)))
                        {
                            mylog(info=>'cache: new cache version, terminating ASAP') if (!($KILL)); 
                            $KILL = 1;
                            $query = '';
                        }



                        if($query eq 'ask')
                        {

                            # check whether IP or IP-Sender are in SPAM cache
                            foreach my $ckey ($ip, $ip.'-'.$sender)
                            {
                                if($cache{$ckey})
                                {
                                    my $tdiff = $time - $cache{$ckey}[2];
                                    
                                    if( ($cache{$ckey}[1] <= 0) &&
                                        ($tdiff > $NTIME)
                                      )
                                    {
                                        # NTTL reached and client retried it
                                        # after NTIME seconds
                                        
                                        $ret = '0';
                                        delete($cache{$ckey});
                                        --$cache_cnt;

                                    }
                                    else
                                    {
                                        if($tdiff > $NTIME)
                                        {
                                            $cache{$ckey}[1] -= 1;
                                        }
                                        $ret = $CACHEREJECTMSG.
                                            ' - retrying too fast. penalty: '.
                                            $NTIME.' seconds x '.
                                            $cache{$ckey}[1].' retries.';
                                            $cache{$ckey}[2] = $time;
                                            last;
                                    }
                                }
                            }

                            if(!($ret))
                            {
                                # ask the HAM cache

                                my $ckey = $ip.'-'.$domain;
                                if($poscache{$ckey})
                                {
                                    $ret = "rate: ";
                                    # check entry time
                                    if($time - $poscache{$ckey}[3] > 
                                                             $my_TEMP_PTIME)
                                    {
                                        if( ($poscache{$ckey}[1] > 0) &&
                                            ($time - $poscache{$ckey}[4] < 
                                                                    $my_PTIME)
                                          )
                                        {
                                            $ret = "rate:hard: ";
                                            $poscache{$ckey}[1] -= 1;
                                        }
                                        else
                                        {
                                            $poscache{$ckey}[1] = $PTTL;
                                            $poscache{$ckey}[4] = $time;
                                        }
                                    }
                                    $ret .= $poscache{$ckey}[0];
                                    $poscache{$ckey}[2] = $time;
                                }
                                
                            }
                        }



                        elsif($query eq 'padd')
                        {
                            my $ckey = $ip.'-'.$domain;
                            ++$poscache_cnt unless $poscache{$ckey};
                            $poscache{$ckey}[0] = $rate;
                            $poscache{$ckey}[1] = $PTTL;
                            $poscache{$ckey}[2] = $time; # last seen
                            $poscache{$ckey}[3] = $time; # TEMP_PTIME
                            $poscache{$ckey}[4] = $time; # PTIME
                            ++$maintenance;
                        }

                        elsif($query eq 'nadd')
                        {
                            my $ckey = $ip;
                            if($domain)
                            {
                                $ckey = $ip.'-'.$sender;
                            }
                            ++$cache_cnt unless $cache{$ckey};
                            $cache{$ckey}[0] = $rate;
                            $cache{$ckey}[1] = $NTTL;
                            $cache{$ckey}[2] = $time;
                            ++$maintenance;
                        }

                        elsif($query =~ /^stat/)
                        {
                            while ( my ($key, $val) = each(%cache) )
                            {
                                $ret .= "blocked: $key ".join(" ",@$val)."\n";
                            }
                            while ( my ($key, $val) = each(%poscache) )
                            {
                                $ret .= "pass: $key ".join(" ",@$val)."\n";
                            }
                            $ret .= "EOF";
                        }

                        elsif($query eq 'reload')
                        {
                            $FORCE_MAINT = 1;
                        }

                        elsif($query eq 'kill')
                        {
                            $KILL = 1;
                        }
                        else
                        {
                            $ret = "unknown cache request: $buf\nEOF";
                        }
                        print $sock $query.$ip.$sender.' '.$ret."\n";
                    }
                    else
                    {
                        $readable_handles->remove($sock);
                        close ($sock);
                    }
            }
        }

        ## kill the cache
        if(($KILL) || (($FORCE_MAINT) && ($CMD_DEBUG)))
        {
            my $dbmsg = '';
            $dbmsg = 'debug ' if $CMD_DEBUG;
            unlink ($SPATH);
            if($lsock) { close ($lsock) };
            mylog  (info=>$dbmsg.'cache killed');
            exit(0);
        }

        if( ($maintenance >= $MAINTENANCE_LEVEL) || ($FORCE_MAINT == 1) )
        {
            $maintenance = 0;
            conf_check('cache');
        }

        ## clean up cache
        if($poscache_cnt > $POSCACHEMAXSIZE) 
        {
            my $purgecnt = 0;
            my $startt = time;
            for(sort { $poscache{$a}[2] <=> $poscache{$b}[2] } keys %poscache)
            {
                if($poscache_cnt > $POSCACHESIZE)
                {
                    delete($poscache{$_});
                    ++$purgecnt;
                    --$poscache_cnt;
                }
                else
                {
                    last;
                }
            }

            if($purgecnt > 0)
            {
                mylog(info=>"cache: purged $purgecnt from HAM cache, time: ".(time - $startt).'s');
            }
        }

        if($cache_cnt > $CACHEMAXSIZE)
        {
            my $purgecnt = 0;
            my $startt = time;
            for(sort { $cache{$a}[2] <=> $cache{$b}[2] } keys %cache)
            {
                if($cache_cnt > $CACHESIZE)
                {
                    delete($cache{$_});
                    ++$purgecnt;
                    --$cache_cnt;
                }
                else
                {
                    last;
                }
            }

            if($purgecnt > 0)
            {
                mylog(info=>"cache: purged $purgecnt from SPAM cache, time: ".(time - $startt).'s');
            }
        }
    }
}



#
# mylog(FACILITY, STRING)
#
# prints FACILITY, STRING on STDOUT when in command-line debug (-d) mode
# otherwise passes it to syslog()
#
sub mylog
{
    my $fac    = shift(@_);
    my $string = join(' ', @_);

    chomp $string;

    if($CMD_DEBUG)
    {
        my $now =  scalar(localtime);
           $now =~ /(\d\d:\d\d:\d\d)/;
        
        print STDERR ("$1 $fac: $string\n");
    }
    else
    {
        my $log_trap;
        if($fac ne 'info')
        {
            $string = $fac.': '.$string;
        }
        $@ = '';
        eval
        {
            local $SIG{'__DIE__'};
            syslog($fac, "%s", $string);
        };
        while($@)
        {
            if($log_trap++ >= 5)
            { 
                emerge_log($fac, $string);
                last;
            }
            select(undef, undef, undef, 0.2); # sleep 0.2 sec
            $@ = '';
            eval
            {
                local $SIG{'__DIE__'};
                syslog($fac, "%s", $string);
            };
        }
    }
}


# emerge_log is a routine which shouldn't die()
# it logs entries in case of syslog absence
# a die() in emerge_log could mean a log-loop
# this routine is not resource optimized
sub emerge_log
{
    local $SIG{__DIE__};
    open(ELOG, ">>$LOCKPATH/polw-emergency.log");
    print ELOG  localtime().' '.
                $syslog_ident.
                '['.$$."]: $syslog_facility: $_[1]\n";
    close ELOG;
}



# rbl_lookup RBL_QUERY [TYPE] 
# returns: 1: found, -1: not found, 0: error, -2: sock err
# remember to give IP octets in reversed order.
# EG: IP: 121.122.123.124, Host: mail.example.com, Rbl: bl.rbl.com
# RBL_QUERY  : "124.123.122.121.bl.rbl.com"
# RHSBL_QUERY: "mail.example.com.bl.rbl.com"
# TYPE       : additonal and usually not needed, default is TXT
# In case of weird errors it tries to use Net::DNS
# You may force the permanent usage of Net::DNS by global setting USE_NET_DNS
sub rbl_lookup
{
        my @bu = @_;
        if($bu[0] =~ /[^.]{64}/) { return (1) }; # see RFC 1035 sect. 2.3.4
 
        while(length($bu[0]) > 255)              # see RFC 1035 sect. 3.1
        {
            $bu[0] =~ s/.*?\.//;
        } 
 
        if(($USE_NET_DNS == 1) || ($] < 5.008000))
        {
            my $answ = $res->send(@bu);
            if   (!($answ))             { return (0)  } # dns error
            elsif(($answ->answer) > 0 ) { return (1)  } # found
            else                        { return (-1) } # not found
        }

        my $query = shift(@bu);
        my $rtype = shift(@bu);
        my $oid   = 1 + int(rand(65535));
           $rtype = 'A' unless ($rtype && $RTYPES{$rtype});

                          # ID    RD      QDCOUNT
        my $p = pack ("n*", $oid, 0x100,  1,        0, 0, 0) .
        
        # concatenate the query and pack it into length preceded labels
                pack ('(C/A*)*', split /\./, $query ).
                pack ('@ (n*)*', $RTYPES{$rtype},      1);
#                                ^QTYPE                ^QCLASS    see: RFC 1035 
      
        $SIG{ALRM} = sub { 
            mylog(warning=>"rbl_lookup: SIGALRM trapped?! Report."); 
            return 
        };
        
        my $buf;
        my $errcnt = 0;
        my $dropped = 0;

        while($s)
        {
            alarm 0; # reset all eventually alarms
            if($dropped==0)
            {
                mylog(info=>"rbl_lookup: sending: $query, $oid") if $DEBUG;

                eval
                {
                    local $SIG{ALRM} = sub { die "ETIMEOUT" };
                    alarm $DNS_RETRY_IVAL;
                    if($s->send($p) < length($p))
                    {
                        mylog(warning=>"rbl_lookup: sent bytes != packet size");
                        ++$errcnt; # timeout or error on sending
                    }
                    alarm 0;
                };

                if($@)
                {
                    ++$errcnt;
                    mylog(warning=>"rbl_lookup: timeout sending: $query") if $DEBUG;
                    next;
                }
            }            
            $dropped = 0;
            my $buf;

            eval
            {
                local $SIG{ALRM} = sub { die "ETIMEOUT" };
                alarm $DNS_RETRY_IVAL;
                $s->recv($buf, 2048);
                alarm 0;
            };

            if((!($buf)) && ($errcnt < $DNS_RETRIES))
            {
                ++$errcnt;
                next;
            }
            elsif((!($buf)) && ($errcnt >= $DNS_RETRIES))
            {
                return(0);  # too many timeouts or errors
            }

            my    ($id, $bf, $qc, $anc, $nsc, $arc, $qb) = 
            unpack('n   n    n    n     n     n     a*', $buf);

            my ($dn, $offset) = dn_expand(\$qb, 0);

            if(($id && $anc) && ($id == $oid) && ($query eq $dn))
            {
                mylog(info=>"rbl_lookup: $query vs $dn, $oid vs $id,  anc == $anc") if $DEBUG;
                return(1);  # found
            }
            elsif($id && (!($anc)) && ($id == $oid) && ($query eq $dn))
            {
                mylog(info=>"rbl_lookup: $query vs $dn, $oid vs $id, anc == 0") if $DEBUG; 
                return(-1); # not found
            }
            elsif(($id && $dn) && (($query ne $dn) || ($id != $oid)))
            {
                mylog(info=>"rbl_lookup: dropped: out:$query vs in:$dn, out:$oid vs in:$id") if $DEBUG;
                $dropped = 1;
                return(0) if $errcnt >= $DNS_RETRIES;
                next;       # wrong packet received, drop
            }
            mylog(warning=>"rbl_lookup: unknown error: out:$query, in:$dn, out-id:$oid, in-id:$id");
            return(0) if $errcnt >= $DNS_RETRIES;
            ++$errcnt;      # unknown error
        }
        mylog(warning=>'RBL Socket died, using Net-DNS now.');
        $USE_NET_DNS = 1;
        return(rbl_lookup(@bu)); # return Net::DNS result
}

sub conf_check
{
    my $who = shift;
    if($conf ne 'default settings')
    {
        my @conf_stat = stat($conf);
        if( $conf_stat[9] != $old_mtime )
        {
            if(sprintf("%04o",$conf_stat[2]) !~ /(7|6|3|2)$/)
            {
                my $conf_str;
                if(open(CONF, $conf))
                {
                    read(CONF,$conf_str,-s CONF);
                    close(CONF);

                    #XXX taint $conf_str as $< enables taint mode
                    ($conf_str) = $conf_str =~ m/(.*)/s;

                    eval $conf_str;
                    if($@)
                    {
                        mylog(warning=>"$who: syntax error in file $conf: ".$@);
                    }
                    else
                    {
                        $old_mtime = $conf_stat[9];
                        ptime_conv();
                        mylog(info=>"$who: $conf reloaded");
                    }
                }
                else
                {
                    mylog(warning=>"$who: could not open $conf: $!");
                }
            }
            else
            {
                 mylog(warning=>"$who: conf-err: $conf is world-writeable! Config not reloaded!");
            }
        }
    }
}


sub create_lockpath
{
    my $who = shift(@_);

    if(!( -d $LOCKPATH))
    {
        mkdir $LOCKPATH or die "$who: error while creating $LOCKPATH: $!";
    }


    #
    # check LOCKPATH, SPATH and cache_lock for being part of symlinks
    #
    check_symlnk( $who, $LOCKPATH, $SPATH, "$LOCKPATH/cache_lock" );


    my $tuid = $USER;

    if($USER =~ /[^0-9]/)
    {
        if( !(defined( $tuid = getpwnam($USER) ) ) )
        {
            mylog(warning=>"User $USER doesn't exist, create it, or set \$USER");
        }
    }
    if( !(chown ($tuid, -1, $LOCKPATH)) )
    {
        mylog(warning=>
            "$who: Couldn't chown $LOCKPATH to $USER ($tuid): $! - UID/EUID: $</$>");
    }
    if( !(chmod (0700, $LOCKPATH)) )
    {
        mylog(warning=>
            "$who: Couldn't set permissions on $LOCKPATH for $USER ($tuid): $! - UID/EUID: $</$>");
    }
}





#
# usage: check_symlnk($caller, @files)
#
# caller: context specifier (eg: "cache: function:")
# files:  list of files to check
sub check_symlnk
{
    my $who = shift;
    for ( @_ )
    {

        my $file = File::Spec->canonpath($_);

        my @stat = lstat( $file );

        if(! -e _)
        {
            next;
        }


        # first, file must not be a symlink
        if ( -l _ )
        {
            fatal_exit("$who: $file is a symbolic link. Symbolic links are not expected and not allowed within policyd-weight. Exiting!");
        }


        # second, file must be owned by uid root or $USER and
        # gid root/wheel or $USER
        if(!(  
                ( 
                    $stat[4] == getpwnam($USER) ||
                    $stat[4] == "0"
                ) &&
                (
                    $stat[5] == getgrnam($GROUP) ||
                    $stat[5] == "0"
                )
            )
          )
        {
            fatal_exit("$who: $file is owned by UID $stat[4], GID $stat[5]. Exiting!");
        }


        # third, the file/dir must not be world writeable
        if(sprintf("%04o",$stat[2]) =~ /(7|6|3|2)$/)
        {
            fatal_exit("$who: $file is world writeable. Exiting!");
        }       


    }
}






# function for sanitizing floating point output
sub myrnd
{
    my $n = index($_[0], ".");
    if($n > 0)
    {
        $n-- if index($_[0], "-") >= 0;
        return(sprintf("%.".($n+3)."g", $_[0]));
    }
    return($_[0]);
}

sub ptime_conv
{
# convert PTIME and TEMP_PTIME to seconds
    my %time_conv;
    $time_conv{'s'} = 1;
    $time_conv{'m'} = 60;
    $time_conv{'h'} = 3600;
    $time_conv{'d'} = 86400;

    my $time_unit;

    if($PTIME =~ /.*?(\d+)([smhd]{0,1}).*/)
    {
        if(!($2)) { $time_unit = 's' }
        else      { $time_unit = $2  }
        $my_PTIME = $1 * $time_conv{$time_unit};
    }
    else
    {
        mylog(warning=>"cache: \$PTIME in wrong format. Using default.");
        $my_PTIME = 10800; # 3 hours
    }

    if($TEMP_PTIME =~ /.*?(\d+)([smhd]{0,1}).*/)
    {
        if(!($2)) { $time_unit = 's' }
        else      { $time_unit = $2  }
        $my_TEMP_PTIME = $1 * $time_conv{$time_unit};   
    }
    else
    {
        mylog(warning=>"cache: \$TEMP_PTIME in wrong format. Using default.");
        $my_TEMP_PTIME = 259200;  # 3 days
    }

    mylog(info=>"cache: PTIME: $my_PTIME, TEMP_PTIME: $my_TEMP_PTIME") if $DEBUG or $VERBOSE;
}


#
# Usage: dns_error(\$query_object, \$res_object)
#
# Returns undef in case of NOERROR or NXDOMAIN
# Returns 1 in all other cases
#
# This function expects references to objects of Net::DNS as arguments
sub dns_error
{
    my ($myquery, $myres) = @_;

    return 1 if not $$myquery;
    return 1 if not $$myres;
    return undef if $$myres->errorstring eq 'NOERROR' or 
                    $$myres->errorstring eq 'NXDOMAIN';
    mylog(debug=>"dns_error: errorstring: ".$$myres->errorstring) if $CMD_DEBUG;
    return 1;
}

#
# returns 1 if the helo is in [n.n.n.n] notation, 
# valid, and matches the client ip
#
sub squared_helo
{
    my $helo = shift;
    my $ip   = shift;

    if($$helo !~ /^\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\]$/ ) { return }
    my $tmp_helo_ip = $1;

    my $tmpip = inet_aton( $tmp_helo_ip );
    
    length($tmpip) or return;

    $tmpip = inet_ntoa($tmpip);

    if($tmpip eq $$ip) { return 1 }

    return 0;
}


