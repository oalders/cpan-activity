#!/usr/bin/env perl

# Reproduce the CPAN activity numbers and charts in "Recent CPAN Activity".
#
# Everything here talks to the public MetaCPAN API (https://api.metacpan.org/)
# using only core Perl modules -- HTTP::Tiny and JSON::PP both ship with Perl, so
# there is nothing to install: a stock perl can verify every figure in the post.
# (Fittingly, you do not need CPAN to measure CPAN.) Run it and you should get the
# same numbers the post reports, subject to CPAN moving underneath you -- new
# uploads keep arriving, and deletions can lower a count.
#
#     perl cpan-activity.pl            # print the report
#     perl cpan-activity.pl --charts   # also (re)write the four SVG charts
#
# Window: 1 January through 31 August (end of day) of each year, applied
# identically to both years so a partial 2026 is compared like-for-like.
#
# Definitions (all derived from the `release` index):
#   uploads               every release, including re-releases of a distribution
#   releasers             distinct PAUSE authors who uploaded anything
#   first-time releasers  authors whose first-EVER CPAN upload lands in the window
#   new distributions     releases flagged `first => true` by MetaCPAN

use strict;
use warnings;
use feature qw(say);

use HTTP::Tiny ();
use JSON::PP qw(encode_json decode_json);
use POSIX qw(ceil);

use constant {
    API       => 'https://api.metacpan.org/v1/release/_search',
    YEAR_A    => 2025,
    YEAR_B    => 2026,
    END_MONTH => '08',    # inclusive; window ends 31 Aug, end of day
    END_DAY   => '31',
};

my @MONTHS = qw(Jan Feb Mar Apr May Jun Jul Aug);

my $HTTP = HTTP::Tiny->new( timeout => 90 );

# POST an Elasticsearch query body to the MetaCPAN release index.
sub search {
    my ($body) = @_;
    my $res = $HTTP->post(
        API,
        {   headers => { 'Content-Type' => 'application/json' },
            content => encode_json($body),
        }
    );
    die "MetaCPAN request failed: $res->{status} $res->{reason}\n$res->{content}\n"
        unless $res->{success};
    return decode_json( $res->{content} );
}

sub window {
    my ($year) = @_;
    return { range => { date => {
        gte => "$year-01-01",
        lte => sprintf( '%d-%s-%sT23:59:59', $year, END_MONTH, END_DAY ),
    } } };
}

# (uploads or new distributions, distinct releasers) for the window.
sub total_and_authors {
    my ( $year, $first_only ) = @_;
    my $query = $first_only
        ? { bool => { filter => [ { term => { first => JSON::PP::true } }, window($year) ] } }
        : window($year);
    my $d = search( {
        size  => 0,
        query => $query,
        aggs  => { authors => { cardinality => { field => 'author' } } },
    } );
    my $total = $d->{hits}{total};
    $total = $total->{value} if ref $total;
    return ( $total, $d->{aggregations}{authors}{value} );
}

# Per-month document counts (uploads, or new distributions), Jan..Aug.
sub monthly_counts {
    my ( $year, $first_only ) = @_;
    my $query = $first_only
        ? { bool => { filter => [ { term => { first => JSON::PP::true } }, window($year) ] } }
        : window($year);
    my $d = search( {
        size  => 0,
        query => $query,
        aggs  => { m => { date_histogram =>
            { field => 'date', calendar_interval => 'month', format => 'MM' } } },
    } );
    my %by = map { $_->{key_as_string} => $_->{doc_count} }
        @{ $d->{aggregations}{m}{buckets} };
    return [ map { $by{ sprintf '%02d', $_ } // 0 } 1 .. 8 ];
}

# Per-month distinct authors (a cardinality sub-agg inside each month), Jan..Aug.
sub monthly_releasers {
    my ($year) = @_;
    my $d = search( {
        size  => 0,
        query => window($year),
        aggs  => { m => {
            date_histogram => { field => 'date', calendar_interval => 'month', format => 'MM' },
            aggs => { authors => { cardinality => { field => 'author' } } },
        } },
    } );
    my %by = map { $_->{key_as_string} => $_->{authors}{value} }
        @{ $d->{aggregations}{m}{buckets} };
    return [ map { $by{ sprintf '%02d', $_ } // 0 } 1 .. 8 ];
}

# Map every CPAN author -> the date (YYYY-MM-DD) of their first release.
# A terms aggregation over authors with a min(date) sub-aggregation, partitioned
# so no single request exceeds Elasticsearch bucket limits.
sub author_first_dates {
    my %first;
    my $num_partitions = 8;
    for my $p ( 0 .. $num_partitions - 1 ) {
        my $d = search( {
            size => 0,
            aggs => { authors => {
                terms => {
                    field   => 'author',
                    size    => 5000,
                    include => { partition => $p, num_partitions => $num_partitions },
                },
                aggs => { first => { min => { field => 'date', format => 'yyyy-MM-dd' } } },
            } },
        } );
        $first{ $_->{key} } = $_->{first}{value_as_string}
            for @{ $d->{aggregations}{authors}{buckets} };
    }
    return \%first;
}

# Per-month count of authors whose first-ever release is in that month, Jan..Aug.
sub firsttime_monthly {
    my ( $first_dates, $year ) = @_;
    my ( $lo, $hi ) = ( "$year-01-01", sprintf( '%d-%s-%s', $year, END_MONTH, END_DAY ) );
    my %counts;
    for my $date ( values %$first_dates ) {
        next unless $date ge $lo && $date le $hi;
        $counts{ substr $date, 5, 2 }++;
    }
    return [ map { $counts{ sprintf '%02d', $_ } // 0 } 1 .. 8 ];
}

sub sum { my $t = 0; $t += $_ for @_; $t }
sub max { my $m = shift; $m = $_ > $m ? $_ : $m for @_; $m }
sub commafy { my $n = reverse shift; $n =~ s/(\d{3})(?=\d)/$1,/g; return scalar reverse $n }
sub pct { my ( $a, $b ) = @_; sprintf '%+.1f%%', ( $b - $a ) / $a * 100 }

# --------------------------------------------------------------------------- #
# SVG chart generation (theme-aware: paints via the site's CSS custom props).
# var() is used in style="" attributes only -- it does NOT resolve inside bare
# SVG presentation attributes like fill="var(--cyan)".
# --------------------------------------------------------------------------- #

use constant { W => 820, H => 340,
    M_TOP => 20, M_RIGHT => 14, M_BOTTOM => 34, M_LEFT => 52 };
use constant {
    PLOT_W => W - M_LEFT - M_RIGHT,
    PLOT_H => H - M_TOP - M_BOTTOM,
};
use constant BASE_Y => M_TOP + PLOT_H;

sub top_rounded {
    my ( $x, $y, $w, $h, $r ) = @_;
    $r //= 4;
    $r = $w / 2 if $r > $w / 2;
    $r = $h     if $r > $h;
    return '' if $h <= 0;
    return sprintf
        'M%.1f,%.1f V%.1f Q%.1f,%.1f %.1f,%.1f H%.1f Q%.1f,%.1f %.1f,%.1f V%.1f Z',
        $x, BASE_Y, $y + $r, $x, $y, $x + $r, $y, $x + $w - $r,
        $x + $w, $y, $x + $w, $y + $r, BASE_Y;
}

sub make_chart {
    my ( $a, $b, $y_max, $ticks, $cid, $title, $unit ) = @_;
    my @p = (
        sprintf( '<svg viewBox="0 0 %d %d" width="100%%" role="img" '
                . 'aria-labelledby="%s-t %s-d" class="cpan-chart" '
                . 'style="font-family:var(--mono)" preserveAspectRatio="xMidYMid meet">',
            W, H, $cid, $cid ),
        qq{<title id="$cid-t">$title</title>},
        qq{<desc id="$cid-d">Grouped bar chart comparing $unit per month, }
            . YEAR_A . ' versus ' . YEAR_B . ', January to August.</desc>',
    );
    for my $t (@$ticks) {
        my $y = BASE_Y - ( $t / $y_max ) * PLOT_H;
        push @p, sprintf(
            '<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke-width="1" style="stroke:var(--border)"/>',
            M_LEFT, $y, W - M_RIGHT, $y );
        push @p, sprintf(
            '<text x="%d" y="%.1f" text-anchor="end" font-size="12" style="fill:var(--muted)">%s</text>',
            M_LEFT - 8, $y + 4, commafy($t) );
    }
    my $group_w = PLOT_W / scalar(@MONTHS);
    my ( $bar_w, $gap ) = ( 26, 3 );
    my $pair_w = $bar_w * 2 + $gap;
    for my $i ( 0 .. $#MONTHS ) {
        my $cx = M_LEFT + $i * $group_w + $group_w / 2;
        my $x0 = $cx - $pair_w / 2;
        my @bars = ( [ YEAR_A, $a->[$i], 'var(--cyan)' ], [ YEAR_B, $b->[$i], 'var(--orange)' ] );
        for my $j ( 0 .. 1 ) {
            my ( $yr, $val, $colour ) = @{ $bars[$j] };
            my $bx = $x0 + $j * ( $bar_w + $gap );
            my $bh = ( $val / $y_max ) * PLOT_H;
            push @p, sprintf(
                '<path d="%s" style="fill:%s"><title>%s %d: %s %s</title></path>',
                top_rounded( $bx, BASE_Y - $bh, $bar_w, $bh ),
                $colour, $MONTHS[$i], $yr, commafy($val), $unit );
        }
        push @p, sprintf(
            '<text x="%.1f" y="%d" text-anchor="middle" font-size="12" style="fill:var(--fg-dim)">%s</text>',
            $cx, BASE_Y + 20, $MONTHS[$i] );
    }
    push @p, sprintf(
        '<line x1="%d" y1="%d" x2="%d" y2="%d" stroke-width="1.5" style="stroke:var(--border-2)"/>',
        M_LEFT, BASE_Y, W - M_RIGHT, BASE_Y );
    push @p, '</svg>';
    return join "\n", @p;
}

sub make_figure {
    my ( $cid, $a, $b, $y_max, $ticks, $title, $unit, $caption ) = @_;
    my $svg = make_chart( $a, $b, $y_max, $ticks, $cid, $title, $unit );
    my $legend = join '',
        '<div class="cpan-chart-legend" style="display:flex;gap:20px;',
        'justify-content:center;font-family:var(--mono);font-size:13px;',
        'color:var(--fg-dim);margin-top:6px">',
        '<span><span style="display:inline-block;width:12px;height:12px;',
        'border-radius:3px;background:var(--cyan);vertical-align:middle;',
        'margin-right:6px"></span>', YEAR_A, '</span>',
        '<span><span style="display:inline-block;width:12px;height:12px;',
        'border-radius:3px;background:var(--orange);vertical-align:middle;',
        'margin-right:6px"></span>', YEAR_B, '</span></div>';
    return
          qq{<figure class="cpan-figure" style="margin:1.5rem 0">\n$svg\n$legend\n}
        . qq{<figcaption style="font-family:var(--mono);font-size:12px;}
        . qq{color:var(--muted);text-align:center;margin-top:8px">$caption</figcaption>\n</figure>\n};
}

# A "nice numbers" axis: pick a round step (1/2/5 x 10^n) aiming for ~4
# gridlines, then the smallest multiple of it that covers the peak. Returns
# ($y_max, \@ticks) with every tick on a round value.
sub axis {
    my ($peak) = @_;
    my $raw  = ( $peak || 1 ) / 4;
    my $mag  = 10**POSIX::floor( log($raw) / log(10) );
    my $norm = $raw / $mag;
    my ($nice) = grep { $_ >= $norm - 1e-9 } ( 1, 2, 5, 10 );
    my $step  = $nice * $mag;
    my $y_max = ceil( $peak / $step ) * $step;
    $y_max += $step if $y_max == $peak;    # headroom so the tallest bar clears the top
    my @ticks;
    for ( my $t = 0; $t <= $y_max + 1e-9; $t += $step ) { push @ticks, $t }
    return ( $y_max, \@ticks );
}

sub main {
    my $write_charts = grep { $_ eq '--charts' } @ARGV;

    my $up_a  = monthly_counts( YEAR_A );
    my $up_b  = monthly_counts( YEAR_B );
    my $nd_a  = monthly_counts( YEAR_A, 1 );
    my $nd_b  = monthly_counts( YEAR_B, 1 );
    my $rel_a = monthly_releasers( YEAR_A );
    my $rel_b = monthly_releasers( YEAR_B );
    my $first = author_first_dates();
    my $ft_a  = firsttime_monthly( $first, YEAR_A );
    my $ft_b  = firsttime_monthly( $first, YEAR_B );

    my ( $up_tot_a, $rel_tot_a ) = total_and_authors( YEAR_A );
    my ( $up_tot_b, $rel_tot_b ) = total_and_authors( YEAR_B );
    my ( $nd_tot_a ) = total_and_authors( YEAR_A, 1 );
    my ( $nd_tot_b ) = total_and_authors( YEAR_B, 1 );
    my ( $ft_tot_a, $ft_tot_b ) = ( sum(@$ft_a), sum(@$ft_b) );

    say sprintf 'CPAN activity, 1 Jan -> 31 Aug, %d vs %d', YEAR_A, YEAR_B;
    say '';
    say sprintf '%-22s%10s%10s%10s', 'metric', YEAR_A, YEAR_B, 'change';
    for my $row (
        [ 'uploads',              $up_tot_a,  $up_tot_b ],
        [ 'releasers',            $rel_tot_a, $rel_tot_b ],
        [ 'first-time releasers', $ft_tot_a,  $ft_tot_b ],
        [ 'new distributions',    $nd_tot_a,  $nd_tot_b ],
    ) {
        say sprintf '%-22s%10d%10d%10s', @$row, pct( $row->[1], $row->[2] );
    }

    say "\nMonthly breakdown (Jan..Aug):";
    for my $row (
        [ 'uploads',           $up_a,  $up_b ],
        [ 'releasers',         $rel_a, $rel_b ],
        [ 'first-time',        $ft_a,  $ft_b ],
        [ 'new distributions', $nd_a,  $nd_b ],
    ) {
        say sprintf '  %-18s %d: [%s]', $row->[0], YEAR_A, join ', ', @{ $row->[1] };
        say sprintf '  %-18s %d: [%s]', '',        YEAR_B, join ', ', @{ $row->[2] };
    }

    return unless $write_charts;

    my @charts = (
        [ 'uploads', $up_a, $up_b, 'CPAN uploads per month', 'uploads',
            'CPAN uploads per month, January–August.' ],
        [ 'releasers', $rel_a, $rel_b, 'Distinct CPAN releasers per month', 'releasers',
            'Distinct CPAN authors releasing each month, January–August.' ],
        [ 'firsttime', $ft_a, $ft_b, 'First-time CPAN releasers per month', 'first-time releasers',
            'Authors making their first-ever CPAN release, by month, January–August.' ],
        [ 'newdist', $nd_a, $nd_b, 'New CPAN distributions per month', 'new distributions',
            'First-time distribution releases per month, January–August.' ],
    );
    for my $c (@charts) {
        my ( $cid, $a, $b, $title, $unit, $cap ) = @$c;
        my ( $y_max, $ticks ) = axis( max( @$a, @$b ) );
        my $fig = make_figure( $cid, $a, $b, $y_max, $ticks,
            sprintf( '%s, %d vs %d', $title, YEAR_A, YEAR_B ),
            $unit, "$cap Source: MetaCPAN API." );
        open my $fh, '>', "$cid.svg.html" or die "$cid.svg.html: $!";
        print {$fh} $fig;
        close $fh;
        say "wrote $cid.svg.html";
    }
}

main();
