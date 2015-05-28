#!/usr/local/bin/perl

use strict;
use warnings;

use JSON::RPC::Legacy::Client;
use DBI;
use Data::Dumper;
use utf8;
use Getopt::Std;
use open qw/ :std :encoding(UTF-8) /;


# ZBX options
#my $zbx_url = 'https://monitoring.example.org/api_jsonrpc.php';
my $zbx_url = 'http://proxy.examplelab.org/api_jsonrpc.php';
my $zbx_authid;
my $zbx_result;
#my $zbx_sync_groupid = 89;  # ZBX host group, the members of which we synchronize
my $zbx_sync_groupid = 8;
my $zbx_user = 'sync_info';
my $zbx_pass = 'l00ksl!ke';
my ($sec, $min, $hour, $day) = localtime;
my $zbx_reqid = '0' . $day . $hour . $min . $sec;

my $zbx_adm = 'ptimofeev@example.org';

# CMDB options
my $cmdb_host = 'sdeskdb';
my $cmdb_user = 'reader';
my $cmdb_pass = 'xbnfntkm';

# The main hash for hosts information
my %hosts;

# Command line arguments
my %cmd_args;
getopts('sdnzh:', \%cmd_args) or &print_help();
&print_help() unless %cmd_args;
&print_help() unless ($cmd_args{'s'} or $cmd_args{'d'} or $cmd_args{'n'});


# Debug options
my $verbose = 0;
my $debug = 0;

my $ca_cert = '/etc/ssl/certs/exampleca.pem';





# Let's go!


# Create a client for ZBX
my $zbx_client = JSON::RPC::Legacy::Client->new;
#$zbx_client->ua->ssl_opts(verify_hostname => 1);
#$zbx_client->ua->ssl_opts(SSL_ca_file => $ca_cert);


# Try to authenticate to ZBX
$zbx_authid = &zbx_call( 'user.login',
    {   user => $zbx_user,
        password => $zbx_pass,
    },
);
print "Authentication successful. Auth ID: " . $zbx_authid . "\n" if $verbose;


# Get list of hosts from ZBX
$zbx_result = &zbx_call( 'host.get',
    {   groupids => $zbx_sync_groupid,
        output => ['hostid', 'name',],
    },
);


# Fill the hosts hash with initial info
foreach my $line (@$zbx_result) {
    my $hostid = $line->{'hostid'};
    my $hostname = $line->{'name'};
    $hosts{$hostid} = {'hostname' => $hostname,};
}
print "Initial %hosts hash obtained from ZBX:\n" if $debug;
print Dumper(\%hosts) if $debug;
print "_" x 40, "\n" if $debug;


# Try to make a connection and authenticate to CMDB
my $dbh = DBI->connect("dbi:Sybase:$cmdb_host", $cmdb_user, $cmdb_pass,
    {   PrintError => 0,        # Don't report errors via warn()
        RaiseError => 1,        # Do report errors via die()
        AutoCommit => 1,
    },
);


# A way to set LongReadLen correctly
$dbh->do("set textsize 32000");


# Fill the hosts hash with main info
foreach my $hostid (keys %hosts) {
    my $hostname = $hosts{$hostid}->{'hostname'};

    # Get info about hosts from CMDB
    my $sql = "SELECT CIT_NAME2 AS software_full, CIT_REMARK AS notes, ITSM_LOCATIONS.LOC_SEARCHCODE AS location, ITSM_PERSONS.PER_EMAIL AS email, ITSM_PERSONS.PER_REMARK AS contact
        FROM ITSM_CONFIGURATION_ITEMS
                LEFT JOIN ITSM_LOCATIONS ON ITSM_CONFIGURATION_ITEMS.CIT_LOC_OID=ITSM_LOCATIONS.LOC_OID
                LEFT JOIN ITSM_PERSONS ON ITSM_CONFIGURATION_ITEMS.CIT_ADMIN_PER_OID=ITSM_PERSONS.PER_OID
                    WHERE CIT_NAME1='$hostname';";

    my $sth = $dbh->prepare($sql);
    $sth->execute;

    while (my $row = $sth->fetchrow_hashref) {
        while (my ($field, $value) = each %$row) {
                utf8::decode($value) if defined $value;
                $hosts{$hostid}->{$field} = $value;
        }
    }
}
print "Incomplete %hosts hash obtained from CMDB: " if $debug;
print Dumper(\%hosts) if $debug;
print "_" x 40, "\n" if $debug;


# Fill the hosts hash with admins info
foreach my $hostid (keys %hosts) {
    my $hostname = $hosts{$hostid}->{'hostname'};

    my $sql = "SELECT PER_REMARK AS contact FROM ITSM_PERSONS WHERE PER_OID IN
        (SELECT CIU_USER_PER_OID FROM ITSM_CI_USERS WHERE CIU_CIT_OID IN
            (SELECT CIT_OID FROM ITSM_CONFIGURATION_ITEMS WHERE CIT_NAME1='$hostname'));";

    my $sth = $dbh->prepare($sql);
    $sth->execute;

    while (my $row = $sth->fetchrow_hashref) {
        while (my ($field, $value) = each %$row) {
            if (defined $value) {
                utf8::decode($value);
                unless ($hosts{$hostid}->{$field}) {
                    $hosts{$hostid}->{$field} = $value;
                } else {
                    $hosts{$hostid}->{$field} = join ', ', $hosts{$hostid}->{$field}, $value;
                }
            }
        }
    }
}
print "Complete %hosts hash obtained from CMDB: " if $debug;
print Dumper(\%hosts) if $debug;
print "_" x 40, "\n" if $debug;


# Disconnect from CMDB
$dbh->disconnect;



# SYNC
if ($cmd_args{'s'}) {
    foreach my $hostid (keys %hosts) {
        my %inventory;
        while (my ($field, $value) = each %{$hosts{$hostid}}) {
            next if ($field eq 'hostname' or $field eq 'email');
            $inventory{$field} = $value;
        }
        $zbx_result = &zbx_call( 'host.update',
            {   hostid => $hostid,
                inventory_mode => 0,
                inventory => \%inventory,
            },
        );
    }
}


# DISPLAY AND NOTIFY
if ($cmd_args{'d'} or $cmd_args{'n'}) {

    my %admins;

    foreach my $hostinfo (values %hosts) {
        my $email = $hostinfo->{'email'};
        my $hostname = $hostinfo->{'hostname'};
        $email = $zbx_adm unless $email;

        while (my ($field, $value) = each %{$hostinfo}) {
            next if ($field eq 'hostname' or $field eq 'email');
            push(@{$admins{$email}->{$hostname}}, $field) unless $value;
        }
    }


    if ($cmd_args{'d'}) {
        print "I would send the following emails: ";
        print Dumper(\%admins);
        print "_" x 40, "\n";
    }

    if ($cmd_args{'n'}) {
        my %rus = (
            contact => 'контактная информация',
            software_full => 'функции и роль',
            notes => 'реакция дежурных на типовые события',
            location => 'местоположение',
        );

        # Send emails
        while (my ($admin, $hosts) = each %admins) {
            my $text;
            if ($cmd_args{'z'}) {
                $text .= "$admin:\n";
                $admin = $zbx_adm;
            }
            foreach my $host (sort keys %{$hosts}) {
                my @rus_fields;
                foreach my $name (@{$hosts->{$host}}) {
                    push @rus_fields, $rus{$name};
                }
                $text .= "$host: ";
                $text .= join ', ', @rus_fields;
                $text .= ".\n";
            }
            &notify($admin, $text);
        }
    }
}




sub zbx_call {
    my ($method, $params) = @_;

    my $json = {
        jsonrpc => "2.0",
        id => $zbx_reqid++,
        auth => $zbx_authid,
        method => $method,
        params => $params,
    };

    my $response = $zbx_client->call($zbx_url, $json);
    print "ZBX responce: " if $debug;
    print Dumper($response->content) if $debug;
    print "_" x 40, "\n" if $debug;

    die "ZBX: The response from server is empty! Status code is '", $zbx_client->status_line, "'.\n" unless $response; 
    die "ZBX: Method '$method' failed. ", $response->error_message->{'data'}, "\n" if $response->is_error;

    $response->result;
}

sub notify {
    my ($to, $text) = @_;

    open (EMAIL, "| /usr/sbin/sendmail -t") or die "Cannot open EMAIL: $!\n";
    print EMAIL <<EOF
From: Zabbix sync <zbx_sync\@example.org>
To: $to
Subject: =?UTF-8?B?0JIgQ01EQiDQvdC10LTQvtGB0YLQsNGC0L7Rh9C90L4g0LjQvdGE0L7RgNC80LDRhtC40Lgh?=
Content-Type: text/plain; charset="utf-8"

ВНИМАНИЕ!
Недостаточно информации о подответственных вам устройствах, добавленных в мониторинг.
Список устройств и недостающей информации:

$text
Пожалуйста, заполните недостающую информацию в CMDB.
EOF
;
    close EMAIL;
}

sub print_help {
    if (exists $cmd_args{'h'} and not defined $cmd_args{'h'}) {
        print "Provide a host list in -h!\n";
    }

    print "Usage:
    $0 [-sdn] [-z] [-h <host list>]

    You should use at least one of these options:
    -s - sync hosts description from cmdb to zabbix;
    -d - just display a list of hosts with empty description fields;
    -n - send email to appropriate admins with a list of hosts with empty description fields;

    -z - send email only to zabbix admins with a list of hosts with empty description fields;

    -h - work only for provided host list;\n";

    exit 1;
}
