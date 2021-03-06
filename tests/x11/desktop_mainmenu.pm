use base "x11test";
use testapi;


sub run() {
    my $self = shift;
    if ( check_var("DESKTOP", "lxde") ) {
        x11_start_program("lxpanelctl menu");    # or Super_L or Windows key
    }
    elsif ( check_var("DESKTOP", "xfce") ) {
        mouse_set( 0, 0 );
        sleep 1;
        send_key "ctrl-esc";                      # open menu
        sleep 1;
        send_key "up";                            # go into Applications submenu
        mouse_hide(1);
    }
    else {
        wait_idle;
        send_key "alt-f1";                        # open main menu
    }
    assert_screen 'test-desktop_mainmenu-1', 20;

    send_key "esc";
}

sub ocr_checklist() {
    [

        { screenshot => 1, x => 30, y => 30,  xs => 200, ys => 250, pattern => "(?si:ccessories.*Internet.*ffice.*Universal .ccess)",                          result => "OK" },    # gnome
        { screenshot => 1, x => 20, y => 5,   xs => 200, ys => 250, pattern => "(?si:reate .auncher.*reate..?older.*pen Terminal Here.*rrange Des.top .cons)", result => "OK" },    # xfce
        { screenshot => 1, x => 56, y => 510, xs => 200, ys => 300, pattern => "(?si:Pers.nal.*Help.*Terminal)",                                               result => "OK" },    # kde 1280x960

        #                {screenshot=>1, x=>20, y=>500, xs=>200, ys=>250, pattern=>"(?si:Accessories.*System.*Logout)", result=>"OK"} # lxde - already matched with img
    ];
}

1;
# vim: set sw=4 et:
