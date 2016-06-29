use v6;
use Test;
use CSS::Declarations;

my $inherit = CSS::Declarations.new: :style("margin-top:5pt; margin-right: 10pt; margin-left: 15pt; margin-bottom: 20pt; color:rgb(0,0,255)");

my $css = CSS::Declarations.new( :style("margin-top:25pt; margin-right: initial; margin-left: inherit"), :$inherit );

nok $css.handling("margin-top"), 'overridden value';
is $css.margin-top, 25, "overridden value";

is $css.handling("margin-right"), "initial", "'initial'";
is $css.margin-right, 0, "'initial'";

is $css.handling("margin-left"), "inherit", "'inherit'";
is $css.margin-left, 15, "'inherit'";

is $css.property("color").inherit, True, 'color inherit metadata';
is $css.color, [0,0,255], "inheritable property";

is $css.property("margin-bottom").inherit, False, 'margin-bottom inherit metadata';
is $css.margin-bottom, 0, "non-inhertiable property";

done-testing;