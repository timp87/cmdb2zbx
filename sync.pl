#!/usr/local/bin/perl

use strict;
use warnings;

use JSON::RPC::Legacy::Client;
use DBI;
use Data::Dumper;
use utf8;
use Encode;
use Getopt::Std;
use open qw(:std :encoding(UTF-8));


# ZBX options
my $zbx_url = 'https://monitoring.example.org/api_jsonrpc.php';
my $zbx_authid;
my $zbx_result;
my $zbx_sync_groupid = 89;  # ZBX host group, the members of which we synchronize
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

# Handle command line arguments
my %cmd_args;
getopts('sdnzvh:', \%cmd_args) or &print_help();
&print_help() unless %cmd_args;
&print_help() unless ($cmd_args{'s'} or $cmd_args{'d'} or $cmd_args{'n'});
my @hostlist;
@hostlist = split /\s+/, $cmd_args{'h'} if $cmd_args{'h'};


# Debug options
my $debug = 0;

my $ca_cert = '/etc/ssl/certs/exampleca.pem';





# Let's go!


# Create a client for ZBX
my $zbx_client = JSON::RPC::Legacy::Client->new;
$zbx_client->ua->ssl_opts(verify_hostname => 1);
$zbx_client->ua->ssl_opts(SSL_ca_file => $ca_cert);


# Try to authenticate to ZBX
$zbx_authid = &zbx_call( 'user.login',
    {   user => $zbx_user,
        password => $zbx_pass,
    },
);
print "Received authID for ZBX: " . $zbx_authid . ".\n" if $cmd_args{'v'};


# Get list of hosts from ZBX
$zbx_result = &zbx_call( 'host.get',
    {   groupids => $zbx_sync_groupid,
        output => ['hostid', 'name',],
        filter => {
            host => \@hostlist,
        },
    },
);
print "Received hosts from ZBX: " . @$zbx_result . ".\n" if $cmd_args{'v'};


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
print "Connecting to CMDB $cmdb_host.\n" if $cmd_args{'v'};
my $dbh = DBI->connect("dbi:Sybase:$cmdb_host", $cmdb_user, $cmdb_pass,
    {   PrintError => 0,        # Don't report errors via warn()
        RaiseError => 1,        # Do report errors via die()
        AutoCommit => 1,
    },
);
print "Connected to CMDB $cmdb_host.\n" if $cmd_args{'v'};


# A way to set LongReadLen correctly for MSSQL
$dbh->do("set textsize 32000");
$dbh->do("use SdeskDB");


# Fill the hosts hash with main info
foreach my $hostid (keys %hosts) {
    my $hostname = $hosts{$hostid}->{'hostname'};

    # Get info about hosts from CMDB
    my $sql = "SELECT CIT_NAME2 AS software_full, ITSM_CIT_4K1.CI1_4K1 AS notes, ITSM_LOCATIONS.LOC_SEARCHCODE AS location, ITSM_PERSONS.PER_EMAIL AS email, ITSM_PERSONS.PER_REMARK AS contact
        FROM ITSM_CONFIGURATION_ITEMS
            LEFT JOIN ITSM_CIT_4K1 ON ITSM_CONFIGURATION_ITEMS.CIT_OID=ITSM_CIT_4K1.CI1_CIT_OID
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


# Fill the hosts hash with additional contacs
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
    print "Syncing to ZBX.\n" if $cmd_args{'v'};
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
    print "Syncing to ZBX done.\n" if $cmd_args{'v'};
}


# DISPLAY AND NOTIFY
if ($cmd_args{'d'} or $cmd_args{'n'}) {
    print "Building hash for notification.\n" if $cmd_args{'v'};

    # Common part. Build new admins hash
    my %admins;

    foreach my $hostinfo (values %hosts) {
        my $email = $hostinfo->{'email'};
        my $hostname = $hostinfo->{'hostname'};
        $email = $zbx_adm unless $email;

        my $count;
        while (my ($field, $value) = each %{$hostinfo}) {
            next if ($field eq 'hostname' or $field eq 'email');
            $count++;
            push (@{$admins{$email}->{$hostname}}, $field) unless $value;
        }
        push (@{$admins{$email}->{$hostname}}, 'noinfo') unless $count;
    }
    print "Building done.\n" if $cmd_args{'v'};


    if ($cmd_args{'d'}) {
        print "I would send the following emails: ";
        print Dumper(\%admins);
        print "_" x 40, "\n";
    }

    if ($cmd_args{'n'}) {
        print "Sending emails.\n" if $cmd_args{'v'};
        my %rus = (
            contact => 'контактная информация',
            software_full => 'функции и роль',
            notes => 'реакция дежурных на типовые события',
            location => 'местоположение',
            noinfo => 'узел отсутствует в CMDB',
        );

        # Send emails
        while (my ($admin, $hosts) = each %admins) {
            my $about;
            if ($cmd_args{'z'}) {
                $about .= "$admin:\n";
                $admin = $zbx_adm;
            }
            foreach my $host (sort keys %{$hosts}) {
                my @rus_fields;
                foreach my $name (@{$hosts->{$host}}) {
                    push @rus_fields, $rus{$name};
                }
                $about .= "$host: ";
                $about .= join ', ', @rus_fields;
                $about .= ".\n";
            }
            &notify($admin, $about);
        }
        print "All emails sent.\n" if $cmd_args{'v'};
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
    my ($to, $body) = @_;
    # Non USASCII characters *in headers* require special encoding
    my $subject = Encode::encode('MIME-B', 'В CMDB недостаточно информации!');
    my $from = Encode::encode('MIME-B', 'Синхронизация Zabbix с CMDB <zbx_sync@example.org>');

    open (my $sendmail, "|-", "/usr/sbin/sendmail -t") or die "Cannot open pipe to EMAIL: $!\n";
    print $sendmail <<EOF;
From: $from
To: $to
Subject: $subject
Content-Type: text/plain; charset="utf-8"
Content-Transfer-Encoding: 8bit

ВНИМАНИЕ!
Недостаточно информации о подответственных вам устройствах, добавленных в мониторинг.
Список устройств и недостающей информации:

$body
Пожалуйста, заполните недостающую информацию в CMDB.
EOF

    close $sendmail;
}

sub print_help {
    print "Provide a host list in -h!\n" if (exists $cmd_args{'h'} and not defined $cmd_args{'h'});

    print "Usage:
    $0 [-sdn] [-z] [-v] [-h <host list>]

    WARNING! You should use at least one of these actions:
    -s - sync hosts description from cmdb to zabbix;
    -d - just display a list of hosts with empty description fields;
    -n - send email to appropriate admins with a list of hosts with empty description fields;

    -z - send email only to zabbix admins with a list of hosts with empty description fields;
    -v - verbose output;

    -h - work only for provided host list;\n";

    exit 1;
}
