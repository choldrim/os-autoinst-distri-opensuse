use base "installbasetest";

use testapi;

use strict;
use warnings;
use English;

use Data::Dumper qw(Dumper);
use Carp qw(confess cluck carp croak);

use feature qw/say/;

###################################################################
# linuxrc helpers

sub linuxrc_menu() {
    my ($self, $menu_title, $menu_entry) = @_;
    # get the menu (ends with /^>/)
    my $r = $self->{s3270}->expect_3270(output_delim => qr/^> /);
    ### say Dumper $r;

    # newline separate list of strings when interpolating...
    local $LIST_SEPARATOR = "\n";

    if (!grep /^$menu_title/, @$r) {
        confess "menu does not match expected menu title ${menu_title}\n @${r}";
    }

    my @match_entry = grep /\) $menu_entry/, @$r;

    if (!@match_entry) {
        confess "menu does not contain expected menu entry ${menu_entry}:\n@${r}";
    }

    my ($match_id) = $match_entry[0] =~ /(\d+)\)/;

    my $sequence = ["Clear", "String($match_id)", "ENTER"];

    $self->{s3270}->sequence_3270(@$sequence);
}

sub linuxrc_prompt () {
    my ($self, $prompt, %arg) = @_;

    $arg{value}   //= '';
    $arg{timeout} //= 3;

    my $r = $self->{s3270}->expect_3270(output_delim => qr/(?:\[.*?\])?> /, timeout => $arg{timeout});

    ### say Dumper $r;

    # two lines or more
    # [previous repsonse]
    # PROMPT
    # [more PROMPT]
    # [\[EXPECTED_RESPONSE\]]>

    # newline separate list of strings when interpolating...
    local $LIST_SEPARATOR = "\n";

    if (!grep /^$prompt/, @$r[0..(@$r-1)] ) {
        confess"prompt does not match expected prompt (${prompt}) :\n"."@$r";
    }

    my $sequence = ["Clear", "String($arg{value})", "ENTER"];
    push @$sequence, "ENTER" if $arg{value} eq '';

    $self->{s3270}->sequence_3270(@$sequence);

}


sub ftpboot_menu () {
    my ($self, $menu_entry) = @_;
    # helper vars
    my ($r_screenshot, $r_home_position, $s_home_position, $cursor_row, $row);

    $r_screenshot = $self->{s3270}->expect_3270(clear_buffer => 1, flush_lines => undef, buffer_ready => qr/PF3=QUIT/);

    # choose server

    $r_home_position = $self->{s3270}->send_3270("Home");
    # Perl question:
    # Why can't I just call this function?  why do I need & ??
    # and why this FQDN?
    $s_home_position = &backend::s390x::s3270::nice_3270_status($r_home_position->{terminal_status});

    $cursor_row = $s_home_position->{cursor_row};

    ## say Dumper @$r_screenshot;

    while ( ($row, my $content) = each(@$r_screenshot)) {
        if ($content =~ $menu_entry) {
            last;
        }
    }

    my $sequence = ["Home", ("Down") x ($row-$cursor_row), "ENTER", "Wait(InputField)"];
    ### say "\$sequence=@$sequence";

    $self->{s3270}->sequence_3270(@$sequence);

    return $r_screenshot;
}

###################################################################
require Text::Wrap;

sub hash2parmfile() {
    my ($parmfile_href) = @_;

    # collect the {key => value, ...}  pairs from the hash into a
    # space separated string "key=value ..." of assignments, in the
    # form needed in the parmfile.
    my @parmentries;

    while (my ($k, $v) = each $parmfile_href) {
        push @parmentries, "$k=$v";
    }

    my $parmfile_with_Newline_s = join( " ", @parmentries);

    # Chop this long line up in hunks less than 80 characters wide, to
    # send them to the host with s3270 "String(...)" commands, with
    # additional "Newline" commands to add new lines.

    # Creatively use Text::Wrap for this, with 'String("' as line
    # prefix and '")\n' as line separator.  Actually '")\nNewline\n'
    # is the line separator :)
    local $Text::Wrap::separator;
    $Text::Wrap::separator = "\")\nNewline\n";

    # For the maximum line length for the wrapping, the s3270
    # 'String("")' command characters in each line don't account for
    # the parmfile line length.  The X E D I T editor has a line
    # counter column to the left.
    local $Text::Wrap::columns;
    $Text::Wrap::columns = 79 + length('String("') - length("00004 ");

    $parmfile_with_Newline_s = Text::Wrap::wrap(
        'String("',             # first line prefix
        'String("',             # subsequent lines prefix
        $parmfile_with_Newline_s
    );

    # If there is no 'Newline\n' at the end of the parmfile, the last
    # line was not long enough to split it.  Then add the closing
    # paren and the Newline now.
    $parmfile_with_Newline_s .= "\")\nNewline"
      unless $parmfile_with_Newline_s =~ /Newline\n$/s;

    return $parmfile_with_Newline_s;
}

use backend::s390x::gnah;

#<<< don't perltidy this part:
# it makes perfect sense to have request and response _above_ each other
sub run() {

    my $self = shift;

    # debugging the vncviewer?
    return if (check_var("DEBUG_VNC", "try vncviewer"));

    my $r;

    my $s3270 = new gnah("s3270");

    $self->{s3270} = $s3270;

    say Dumper $s3270;

    eval {

        ###################################################################
	# connect to zVM, login to the guest
	$r = $s3270->connect_and_login();

        ###################################################################
        # ftpboot
	{

	    $s3270->sequence_3270(
		qw{
                   String(ftpboot)
                   ENTER
                   Wait(InputField)
                });

	    my $host = get_var("FTPBOOT")->{HOST};
	    my $distro = get_var("FTPBOOT")->{DISTRO};
	    $r = $self->ftpboot_menu(qr/\Q$host\E/);
	    $r = $self->ftpboot_menu(qr/\Q$distro\E/);
	}

        ##############################
        # edit parmfile
        {
            $r = $s3270->expect_3270(buffer_ready => qr/X E D I T/, timeout => 30);

            $s3270->sequence_3270( qw{ String(INPUT) ENTER } );

            $r = $s3270->expect_3270(buffer_ready => qr/Input-mode/);
            ### say Dumper $r;

            my $parmfile_href = get_var("PARMFILE");

            $parmfile_href->{ssh}='1';

            my $parmfile_with_Newline_s = &hash2parmfile($parmfile_href);

            my $sequence = <<"EO_frickin_boot_parms";
${parmfile_with_Newline_s}
ENTER
ENTER
EO_frickin_boot_parms

            # can't use qw{} because of space in commands...
            $s3270->sequence_3270(split /\n/, $sequence);

            $r = $s3270->expect_3270(buffer_ready => qr/X E D I T/);

            $s3270->sequence_3270( qw{ String(FILE) ENTER });
        }
        ###################################################################
        # linuxrc

        # wait for linuxrc to come up...
        $r = $s3270->expect_3270(output_delim => qr/>>> Linuxrc/, timeout=>20);
        ### say Dumper $r;

        $self->linuxrc_menu("Main Menu", "Start Installation");
        $self->linuxrc_menu("Start Installation", "Start Installation or Update");
        $self->linuxrc_menu("Choose the source medium", "Network");
        $self->linuxrc_menu("Choose the network protocol", get_var("INSTSRC")->{PROTOCOL});

        if (get_var("PARMFILE")->{ssh} eq "1") {
            $self->linuxrc_prompt("Enter your temporary SSH password.",
                                  value => "SSH!554!");
        }

        if (check_var("NETWORK", "hsi-l3")) {
            $self->linuxrc_menu("Choose the network device",
                                "\QIBM Hipersocket (0.0.7000)\E");

            $self->linuxrc_prompt("Device address for read channel");
            $self->linuxrc_prompt("Device address for write channel");
            $self->linuxrc_prompt("Device address for data channel");

            $self->linuxrc_menu("Enable OSI Layer 2 support", "No");
            $self->linuxrc_menu("Automatic configuration via DHCP", "No");

        }
        elsif (check_var("NETWORK", "hsi-l2")) {
            $self->linuxrc_menu("Choose the network device",
                                "\QIBM Hipersocket (0.0.7100)\E");

            $self->linuxrc_prompt("Device address for read channel");
            $self->linuxrc_prompt("Device address for write channel");
            $self->linuxrc_prompt("Device address for data channel");

            ## FIXME which mac address if YES?
            $self->linuxrc_menu("Enable OSI Layer 2 support", "Yes");
            $self->linuxrc_prompt("\QMAC address. (Enter '+++' to abort).\E");
            $self->linuxrc_menu("Automatic configuration via DHCP", "No");

        }
        elsif (check_var("NETWORK", "ctc")) {
            $self->linuxrc_menu("Choose the network device", "\QIBM parallel CTC Adapter (0.0.0600)\E");
            $self->linuxrc_prompt("Device address for read channel");
            $self->linuxrc_prompt("Device address for write channel");
            $self->linuxrc_menu("Select protocol for this CTC device", "Compatibility mode");
            $self->linuxrc_menu("Automatic configuration via DHCP", "No");
        }
        elsif (check_var("NETWORK", "vswitch-l3")) {
            $self->linuxrc_menu("Choose the network device", "\QIBM OSA Express Network card (0.0.0700)\E");
            $self->linuxrc_menu("Please choose the physical medium", "Ethernet");

            ## in our set up, the default just works
            $self->linuxrc_prompt("Enter the relative port number");

            $self->linuxrc_prompt("Device address for read channel");
            $self->linuxrc_prompt("Device address for write channel");
            $self->linuxrc_prompt("Device address for data channel");

            $self->linuxrc_prompt("\QPortname to use\E");

            $self->linuxrc_menu("Enable OSI Layer 2 support", "No");

            $self->linuxrc_menu("Automatic configuration via DHCP", "No");

        }
        elsif (check_var("NETWORK", "vswitch-l2")) {
            $self->linuxrc_menu("Choose the network device", "\QIBM OSA Express Network card (0.0.0800)\E");
            $self->linuxrc_menu("Please choose the physical medium", "Ethernet");

            ## in our set up, the default just works
            $self->linuxrc_prompt("Enter the relative port number");

            $self->linuxrc_prompt("Device address for read channel");
            $self->linuxrc_prompt("Device address for write channel");
            $self->linuxrc_prompt("Device address for data channel");

            $self->linuxrc_prompt("\QPortname to use\E");

            $self->linuxrc_menu("Enable OSI Layer 2 support", "Yes");
            $self->linuxrc_prompt("\QMAC address. (Enter '+++' to abort).\E");

            ## TODO: vswitch L2 += DHCP
            $self->linuxrc_menu("Automatic configuration via DHCP", "No");

        }
        elsif (check_var("NETWORK", "iucv")) {
            $self->linuxrc_menu("Choose the network device", "\QIBM IUCV\E");

            $self->linuxrc_prompt("\QPlease enter the name (user ID) of the target VM guest\E",
                value => "ROUTER01");

            $self->linuxrc_menu("Automatic configuration via DHCP", "No");
        }
        else {
            confess "unknown network device in vars.json: NETWORK = ${get_var('NETWORK')}";
        };

        # FIXME work around https://bugzilla.suse.com/show_bug.cgi?id=913723
        # normally use value from parmfile.
        $self->linuxrc_prompt("Enter your IPv4 address",
                              value => get_var("PARMFILE")->{HostIP});

        # FIXME: add NETMASK parameter to test "Entr your Netmask" branch
        # for now, give the netmask with the IP where needed.
        #if (check_var("NETWORK", "hsi-l3")||
        #    check_var("NETWORK", "hsi-l2")||
        #    check_var("NETWORK", "vswitch-l3")) {
        #    $self->linuxrc_prompt("Enter your netmask. For a normal class C network, this is usually 255.255.255.0.",
        #                          timeout => 10, # allow for the CTC peer to react
        #        );
        #}

        if (check_var("NETWORK", "hsi-l3")     ||
            check_var("NETWORK", "hsi-l2")     ||
            check_var("NETWORK", "vswitch-l2") ||
            check_var("NETWORK", "vswitch-l3")) {

            $self->linuxrc_prompt("Enter the IP address of the gateway. Leave empty if you don't need one.");
            $self->linuxrc_prompt("Enter your search domains, separated by a space",
                                  timeout => 10);
        }
        elsif (check_var("NETWORK", "ctc") ||
               check_var("NETWORK", "iucv")) {
            # FIXME why is this needed?  it is in the parmfile!
            $self->linuxrc_prompt("Enter the IP address of the PLIP partner.",
                                  value   => get_var("PARMFILE")->{Gateway});

        };

        # use value from parmfile
        $self->linuxrc_prompt("Enter the IP address of your name server.",
                              timeout => 10);

        if (get_var("INSTSRC")->{PROTOCOL} eq "HTTP" ||
            get_var("INSTSRC")->{PROTOCOL} eq "FTP" ||
            get_var("INSTSRC")->{PROTOCOL} eq "NFS") {

            $self->linuxrc_prompt("Enter the IP address of the (HTTP|FTP|NFS) server",
                                  value => get_var("INSTSRC")->{HOST});

            $self->linuxrc_prompt("Enter the directory on the server",
                                  value => get_var("INSTSRC")->{DIR_ON_SERVER});
        }
        else {
            confess "unknown installation source in vars.json: INSTSRC = ${get_var('INSTSRC')}";
        };

        if (get_var("INSTSRC")->{PROTOCOL} eq "HTTP" ||
            get_var("INSTSRC")->{PROTOCOL} eq "FTP") {
            $self->linuxrc_menu("Do you need a username and password to access the (HTTP|FTP) server",
                                "No");

            $self->linuxrc_menu("Use a HTTP proxy",
                                "No");
        }

        $r = $s3270->expect_3270(
            output_delim => qr/Reading Driver Update/,
            timeout      => 50
            );

        ### say Dumper $r;

        $self->linuxrc_menu("Select the display type",
                            get_var("DISPLAY")->{TYPE});

        if (get_var("DISPLAY")->{TYPE} eq "VNC") {
            $self->linuxrc_prompt("Enter your VNC password",
                                  value => get_var("DISPLAY")->{PASSWORD});
        }
        elsif (get_var("DISPLAY")->{TYPE} eq "X11") {
            $self->linuxrc_prompt("Enter the IP address of the host running the X11 server.",
                                  value => "");
        }
        elsif (get_var("DISPLAY")->{TYPE} eq "SSH") {

        };

        $r = $s3270->expect_3270(
            output_delim => qr/\Q*** Starting YaST2 ***\E/,
            timeout      => 20
            );
    };

    # while developing: cluck.  in real life:  confess!
    # confess $@ if $@;
    cluck $@if $@;

    ###################################################################
    # now connect to the running VNC server
    # FIXME: this should connect to the terminal, ssh or vnc or X11...
    # and for SSH it then needs to start yast.
    $bmwqemu::backend->connect_vnc();

    ### say Dumper $r;

}
#>>> perltidy again from here on

1;
