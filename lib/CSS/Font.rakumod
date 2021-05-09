use v6;
class CSS::Font {
    use CSS::Properties;
    use CSS::Properties::Calculator :FontWeight;
    use CSS::Units :pt;

    has FontWeight $.weight is rw = 400;
    has Str @!family = ['times-roman'];
    method family { @!family[0] }
    has Str $.style = 'normal';
    has Numeric $.line-height;
    has Str $.stretch;
    has CSS::Properties $.css handles <em ex measure units viewport-width viewport-height Str> .= new();
    method css is rw {
        Proxy.new(
            FETCH => sub ($) { $!css },
            STORE => sub ($, $!css) { self.setup },
        );
    }

    submethod TWEAK(Str :$font-style, Str :$font-props) {
        with $font-style {
            warn 'CSS::Properties::Font.new(:$font-style) is deprecated. Please use :$font-props';
            self.font-props = $_;
        }
        self.font-props = $_ with $font-props;
        self.setup;
    }

    #| compute a fontconfig pattern for the font
    method fontconfig-pattern {
        my Str $pat = @!family.join: ',';

        $pat ~= ':slant=' ~ $!style
            unless $!style eq 'normal';

        $pat ~= ':weight='
        #    000  100        200   300  400     500    600      700  800       900
          ~ <thin extralight light book regular medium semibold bold extrabold black>[$!weight.substr(0,1)]
            unless $!weight == 400;

        # [ultra|extra][condensed|expanded]
        $pat ~= ':width=' ~ $!stretch.subst(/'-'/, '')
            unless $!stretch eq 'normal';
        $pat;
    }

    #| sets/gets the css font properties as a whole
    #| e.g. $font.font-css = 'italic bold 10pt/12pt sans-serif';
    method font-props is rw {
        Proxy.new(
            FETCH => sub ($) { $!css.font },
            STORE => sub ($, Str \font-props) {
                $!css.font = font-props;
                self.setup;
            });
    }
    method font-style(|c) is rw is DEPRECATED<font-props> { self.font-props(|c) }

    method setup(CSS::Properties $css = $!css) {
        @!family = [];
        with $css.font-family {
            for .grep(* ne ',') {
                if .type eq 'keyw' {
                    $_ ~= ' ' with @!family.tail;
                    @!family.tail ~= $_;
                }
                else {
                    @!family.push: $_;
                }
            }
        }
        @!family[0] //= 'arial';

        $!style = $css.font-style;
        $!weight = $css.computed('font-weight');
        $!stretch = $css.font-stretch;
        $!line-height = $css.measure(:line-height);
	self;
    }

    method find-font(Str $name = $.fontconfig-pattern) {
        my $cmd =  run('fc-match',  '-f', '%{file}', $name, :out, :err);
        given $cmd.err.slurp {
            note chomp($_) if $_;
        }
        my $file = $cmd.out.slurp;
        $file
          || die "unable to resolve font-name: $name"
    }
}

