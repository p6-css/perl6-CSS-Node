#| Optimizer for CSS Property ASTs
unit class CSS::Properties::Optimizer;

use NativeCall;
has CArray $.index is required;
has $.css is required;

my subset ZeroPoint of Associative where {
    # e.g. { :px(0) } === { :mm(0.0) }
    with .values[0] { $_ ~~ Numeric && $_ =~= 0 }
}

multi sub css-eqv(%a, %b) {
    return True if %a ~~ ZeroPoint && %b ~~ ZeroPoint;
    if %a.elems != %b.elems { return False }
    for %a.kv -> $k, $v {
        return False
            unless %b{$k}:exists && css-eqv($v, %b{$k});
    }
    True;
}
multi sub css-eqv(@a, @b) {
    if +@a != +@b { return False }
    for @a.kv -> $k, $v {
        return False
            unless css-eqv($v, @b[$k]);
    }
    True;
}
multi sub css-eqv(Numeric:D $a, Numeric:D $b) { $a == $b }
multi sub css-eqv(Stringy $a, Stringy $b) { $a eq $b }
multi sub css-eqv(Any $a, Any $b) is default {
    !$a.defined && !$b.defined
}

#| determine if it is advantageous to combine component properties
#| into container properties, e.g. font-family font-style ... into font
proto sub optimizable(Str $cont-prop, :%props) { * }

# cue-after requires a cue-before entry
multi sub  optimizable('cue', :%props) { %props<cue-before>:exists }

# Avoid these font serialization optimizations, which won't parse correctly:
#     font: bold;            // font-weight or font-style only
#     font: bold Helvetica;  // ... + family-name
# Need a font-size or font-family to disambiguate, e.g.:
#     font: bold medium Helvetica;
#     font: medium Helvetica;
multi sub optimizable('font', :%props (:$font-size, :$font-family, |c) ) {
    $font-size.defined && $font-family.defined;
}

multi sub optimizable(Str $, :props(%)) {
    True;
}

method optimize( @ast, Bool :$keep-defaults ) {
    my %prop-ast;
    for @ast.grep(*.key eq 'property') {
        my %v = .value;
        %prop-ast{$_} = %v
            with %v<ident>:delete;
    }

    self.purge-defaults(%prop-ast)
        unless $keep-defaults;
    self.optimize-ast(%prop-ast);
    tweak-properties(%prop-ast);
    make-declaration-list(%prop-ast);
}

has Array $!container-properties;
method !container-properties {
    $!container-properties //= [$!index.grep(*.children).map(*.name)];
}

sub tweak-properties($_) is export(:tweak-properties) {
    with .<font> {
        given .<expr> -> @expr {
            with @expr.first({.<expr:line-height>}, :k) {
                # reinsert font '/' operator if needed...
                # e.g.: font: italic bold 10pt/12pt times-roman;
                splice @expr, $_, 0, %(:op('/'))
                    unless $_ == 0 || @expr[$_-1]<op> ~~ '/';
            }
        }
    }
}

multi sub make-declaration-list(%prop-ast) is export(:make-declaration-list) {
    my @declaration-list = %prop-ast.keys.sort.map: -> \prop {
        my %property = %prop-ast{prop};
        %property<ident> = prop;
        %property;
    };

    :@declaration-list;
}

method purge-defaults(%prop-ast) {
   for %prop-ast.keys.sort -> \prop {
        # delete properties that match the default value
        my \info = $!css.info(prop);

        with %prop-ast{prop}<expr> -> \val {
            %prop-ast{prop}:delete
                if (val ~~ List ?? css-eqv(val, info.default-value) !! css-eqv(val[0], info.default-value[0]));
        }
   }
}

method optimize-ast( %prop-ast ) {
    my Int @parent-props = %prop-ast.keys.map({$!css.info($_).edge}).grep(*).sort;

    # consolidate box properties with common values
    # margin-right: 1pt; ... margin-bottom: 1pt -> margin: 1pt
    for @parent-props -> Int $prop {
        # bottom up aggregation of edges. e.g. border-top-width, border-right-width ... => border-width
        my \info = $!css.info($prop);
        next unless info.box;
        my @edges;
        my @asts;

        for info.edges -> \side {
            my $prop := $!css.property-name(side);
            with %prop-ast{$prop} {
                @edges.push: $prop;
                @asts.push: $_;
            }
            else {
                last;
            }
        }

        if @asts == 4 && @asts.map( *<prio> ).unique == 1 {
            # all edges present at the same priority; consolidate
            %prop-ast{$_}:delete for @edges;

            my constant DefaultIdx = [Mu, Mu, 0, 0, 1];
            @asts.pop
                while +@asts > 1
                && css-eqv( @asts.tail, @asts[ DefaultIdx[+@asts] ] );

            my @expr = flat @asts.map(*<expr>.list);

            my $name = $!css.property-name($prop);
            %prop-ast{$name} = { :@expr };
            %prop-ast{$name}<prio> = $_
                with @asts[0]<prio>;
        }
    }
    for self!container-properties.list -> \container-prop {
        # top-down aggregation of container properties. e.g. border-width, border-style => border

        my @children = $!css.info(container-prop).child-names.grep: {
            %prop-ast{$_}:exists
        }
        next unless @children;

        # agregrate related children to a container property, where possible.
        # -- if child properties are 'initial', or 'inherit', they all
        #    need to be present and the same
        # -- otherwise they need to all need to have or lack
        #    the !important indicator

        my %groups = @children.classify: -> $p {
            given %prop-ast{$p} {
                when (.<expr>.elems > 1 && $!css.info($p).box)
                || .<expr>[0]<keyw> ~~ 'initial'|'inherit' {
                    'omit'
                }
                when .<prio> ~~ 'important' {'important'}
                default {'normal'}
            }
        }

        %groups<omit>:delete;

        #| find largest consolidation group
        my $group = .key
            with %groups.pairs.sort(*.key).sort({+.value}).tail;

        with $group {
            # all of the same type
            given %groups{$_}.list -> @children {
                when 'initial'|'inherit' {
                    %prop-ast{$_}:delete for @children;
                    %prop-ast{container-prop} = { :expr[ :keyw($_) ] };
                }
                when 'important'|'normal' {
                    my %props = %(@children.Set);
                    if optimizable(container-prop, :%props) {
                        my %ast = :expr[ @children.map: {
                            my \sub-prop = %prop-ast{$_}:delete;
                            'expr:'~$_ => sub-prop<expr>;
                        } ];
                        %ast<prio> = $_
                            when 'important';
                        %prop-ast{container-prop} = %ast;
                    }
                }
            }
        }
    }
    %prop-ast;
}

