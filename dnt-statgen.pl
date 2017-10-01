#!/usr/bin/env perl

#============================================================================
# /dev/null/nethack Tribute 2017 Statistics Generator
# """""""""""""""""""""""""""""""""""""""""""""""""""
# (c) 2017 Borek Lupomesky
#
# Scoreboard generator for /dev/null/nethack Tribute 2017. Please see README
# for documentation on how this works.
#============================================================================

use strict;
use warnings;
use utf8;
use integer;

use Carp;
use Getopt::Long;
use JSON;
use Template;
use DBI;


#============================================================================
#=== definitions ============================================================
#============================================================================

my $lockfile = '/tmp/dnt-statgen.lock';



#============================================================================
#=== global variables =======================================================
#============================================================================

# configuration, parsed from external file

my $cfg;

# array of function references that are called for each xlogfile row

my @row_consumers;

# array of function references taht are called after the whole xlogfile is
# read in

my @glb_consumers;

# the complete scoreboard data are held in this variable; this is the data
# that are supplied to Template Toolkit templates for rendering the actual
# web pages; the structure is described in the README.md

my %s;
$s{'games'}{'data'}{'all'} = [];
$s{'games'}{'data'}{'ascended'} = [];
$s{'trophies'}{'recognition'} = {};



#============================================================================
#=== stuff to do at startup =================================================
#============================================================================

BEGIN
{
  my $js = new JSON->relaxed(1);
  local $/;

  #--- read configuration file

  open(my $fh, '<', 'dnt.conf') or die 'Failed to open configuration file';
  my $config = <$fh>;
  close($fh);
  $cfg = $js->decode($config);
}



#============================================================================
#=== functions ==============================================================
#============================================================================

#============================================================================
# Split a line along field separator, parse it into hash and return it as
# a hashref.
#============================================================================

sub parse_log
{
  my $l = shift;
  my %l;
  my (@a1, @a2, $a0);

  #--- there are two field separators in use: comma and horizontal tab;
  #--- we use simple heuristics to find out the one that is used for given
  #--- xlogfile row

  @a1 = split(/:/, $l);
  @a2 = split(/\t/, $l);
  $a0 = scalar(@a1) > scalar(@a2) ? \@a1 : \@a2;

  #--- split keys and values

  for my $field (@$a0) {
    my ($key, $val) = split(/=/, $field);
    $l{$key} = $val;
  }

  #--- finish returning hashref

  return \%l
}


#============================================================================
# Return number of conducts or list of conduct abbreviations.
#============================================================================

sub conduct
{
  my $conduct = shift;
  my @cond_list;

  my @conducts = (
    [ 1024, "arti" ],
    [  128, "pile" ],
    [  256, "self" ],
    [ 2048, "geno" ],
    [  512, "wish" ],
    [    8, "athe" ],
    [    4, "vegt" ],
    [    2, "vegn" ],
    [   16, "weap" ],
    [   64, "illi" ],
    [   32, "paci" ],
    [    1, "food" ],
  );

  for my $e (@conducts) {
    if($e->[0] & eval($conduct)) {
      push(@cond_list, $e->[1]);
    }
  }

  return wantarray ? @cond_list : scalar(@cond_list);
}


#============================================================================
# Function to get xlogfile row records for given game indexes. If the passed
# into arguments are refs, then they are returned without change.
#============================================================================

sub get_xrows
{
  my @result;

  for my $g (@_) {
    if(!defined $g) { croak('Argument not defined'); }
    my $r = ref($g) ? $g : $s{'games'}{'data'}{'all'}[$g];
    push(@result, (ref($g) ? $g : $s{'games'}{'data'}{'all'}[$g]));
  }

  return scalar(@result) > 1 ? @result : $result[0];
}


#============================================================================
# Returns whether game is ascended.
#============================================================================

sub is_ascended
{
  my $g = shift;

  #--- validate argument

  if(!defined $g) { croak "Assertion failed, required argument missing"; }

  #--- get the game data

  my $xrow = ref($g) ? $g : get_xrows($g);
  if(!ref($xrow)) { croak 'Assertion failed ($xrow not a ref)'; }
  if($xrow !~ /^HASH/) { croak 'Assertion failed ($xrow not a hashref)'; }

  #--- return result

  return $xrow->{'death'} =~ /^ascended/;
}


#============================================================================
# Get a string representation of a game combination (such as
# Wiz-Elf-Mal-Cha). Both game index and row hashref are accepted.
#============================================================================

sub str_combo
{
  my $g = shift;

  #--- validate argument

  if(!defined $g) { croak 'Assertion failed, required argument missing'; }

  #--- get the game data

  my $xrow = ref($g) ? $g : get_xrows($g);
  if(!ref($xrow)) { croak 'Assertion failed, $xrow is not a ref'; }
  if($xrow !~ /^HASH/) { croak 'Assertion failed, $xrow is not a hashref'; }

  #--- return result

  return sprintf(
    '%s-%s-%s-%s',
    @{$xrow}{'role', 'race', 'gender0', 'align0'}
  );
}


#============================================================================
# Gets list of games as an argument and returns hashref with following keys:
#  - cnt   ... number of non-repeating ascensions
#  - games ... list of games that achieved this result
#  - when  ... endtime of the last game
#============================================================================

sub combo_ascends_nrepeat
{
  my %result = (cnt => 0);

  #--- list of ascending games

  my @games = grep { is_ascended($_) } @_;
  if(!@games) { return \%result; }

  #--- perform the count

  my %seen;
  my @games_nrepeat;
  for my $g (@games) {
    my $c = str_combo($g);
    if(!exists $seen{$c}) {
      $seen{$c} = 1;
      push(@games_nrepeat, $g);
    }
  }

  #--- get results

  my $last_game = get_xrows($games_nrepeat[-1]);
  $result{'cnt'} = scalar(@games_nrepeat);
  $result{'games'} = \@games_nrepeat;
  $result{'when'} = $last_game->{'endtime'};

  #--- finish

  return \%result;
}


#============================================================================
# Factory function to generate trophy tracker for a particular trophy. The
# trophy is selected by using the tracked categories: genders, alignments,
# races, roles, conducts.
#
# /dev/null/nethack Recognition Trophies trackers are obtained by the
# following invocations:
#
# Full Monty ... trophy_state(qw(genders alignments races roles conducts))
# Grand Slam ... trophy_state(qw(genders alignments races roles))
# Hat Trick  ... trophy_state(qw(genders alignments races))
# Double Top ... trophy_state(qw(genders alignments))
# Birdie     ... trophy_state(qw(genders))
#
# If the trophy is to be achieved in consecutive games ("with the bells on")
# the calling sub can reset the tracker by simply creating a new one.
#
# The tracker accepts data as a list of hashrefs, like in following example.
#
#    $tracker->({ genders => 'Mal' });
#    $tracker->({ genders => 'Mal' }, { role = 'Cav' });
#    $tracker->({ conducts => ['arti','wish','self','pile'] });
#
# The tracker returns true/false depending whether the trophy was achieved.
# Calling the tracker without any arguments is allowed.
#============================================================================

sub trophy_state
{
  #--- the state tracking structure

  my %state = (
    'genders' => { 'mal' => 0, 'fem' => 0 },
    'alignments' => { 'law' => 0, 'neu' => 0, 'cha' => 0 },
    'races' => { 'hum' => 0, 'dwa' => 0, 'elf' => 0, 'orc' => 0, 'gno' => 0 },
    'roles' => {
      'arc' => 0, 'bar' => 0, 'cav' => 0, 'hea' => 0, 'kni' => 0, 'mon' => 0,
      'pri' => 0, 'ran' => 0, 'rog' => 0, 'sam' => 0, 'tou' => 0, 'val' => 0,
      'wiz' => 0
     },
    'conducts' => {
      'arti' => 0, 'pile' => 0, 'self' => 0, 'geno' => 0, 'wish' => 0,
      'athe' => 0, 'vegt' => 0, 'vegn' => 0, 'weap' => 0, 'illi', => 0,
      'food' => 0, 'paci' => 0
    }
  );

  #--- tracked trophies

  my @trophies = @_;

  #--- state tracking function

  return sub {

  #--- accept new info

    for my $e (@_) {

      # process arguments
      if(!ref($e)) { croak "Argument to trophy_state() is not hashref"; }
      my @ek = (keys %$e);

      for my $ek (@ek) {
        my $ev = $e->{$ek};
        if(!ref($ev)) { $ev = [ $ev ]; }
        if(!exists $state{$ek}) {
          croak "Argument to trophy_state() key='$ek' is invalid";
        }

        # perform state update
        for my $val (@$ev) {
          if(!exists($state{$ek}{lc($val)})) {
            croak "Argument to trophy_state() key='$ek' value='$val' is invalid";
          }
          $state{$ek}{lc($val)} = 1;
        }
      }
    }

  #--- evaluate state

    my $result = 1;
    OUTER: for my $t (@trophies) {
      for my $v (keys %{$state{$t}}) {
        if(!$state{$t}{$v}) {
          $result = 0;
          last OUTER;
        }
      }
    }

    return $result;
  };

}


#============================================================================
# Factory function for tracking recognition multi-game trophies. It is called
# as trophy_track(TROPHY, WITH_BELLS_ON) and returns a tracker function.
#============================================================================

sub trophy_track
{
  #--- arguments

  my ($trophy, $with_bells_on) = @_;

  #--- define the trophies

  my %trophies = (
    'birdie'    => [ 'genders' ],
    'doubletop' => [ 'genders', 'alignments' ],
    'hattrick'  => [ 'genders', 'alignments', 'races' ],
    'grandslam' => [ 'genders', 'alignments', 'races', 'roles' ],
    'fullmonty' => [ 'genders', 'alignments', 'races', 'roles', 'conducts' ]
  );

  #--- validate argument

  if(!exists($trophies{$trophy})) {
    croak "Unknown trophy '$trophy' requested";
  }

  #--- achieved flag, this turns to aref when the trophy is achieved

  my $achieved;

  #--- tracker function for keeping state of the trophy

  my $tracker = trophy_state(@{$trophies{$trophy}});

  #--- trophy tracker function

  return sub {

    # argument, both index and actual rows accepted
    my $game = shift;
    $game = get_xrows($game) if defined $game;

    # just return the status if the trophy is already achieved or the caller
    # is only requesting current status
    return $achieved if $achieved || !defined $game;

    # non-ascending games break the trophy WBO
    if(!is_ascended($game) && $with_bells_on) {
      $tracker = trophy_state(@{$trophies{$trophy}});
      return undef;
    }

    if(is_ascended($game)) {
      if($tracker->({
        'genders' => $game->{'gender0'},
        'alignments' => $game->{'align0'},
        'races' => $game->{'race'},
        'roles' => $game->{'role'},
        'conducts' => [ conduct($game->{'conduct'}) ]
      })) {
        $achieved = [ $game->{'_id'} ];
      };
    }

  #--- finish

    return $achieved;
  };
}


#============================================================================
# Template processing.
#============================================================================

sub process_templates
{
  #--- arguments

  my (
    $subdir,     # 1. source directory with templates (relative to base)
    $data,       # 2. hashref to templates data
    $iter_var,   # 3. (optional) iteration variable
    $iter_vals   # 4. (optional) iteration values
  ) = @_;

  #--- if no iteration over different values is required, we create dummy
  #--- list with one undefined element (so that the loop gets executed once)

  if(!defined $iter_vals) { $iter_vals = [ undef ]; }

  #--- initialize Template Toolkit

  my $src_path = $cfg->{'templates'}{'path'} . '/' . ($subdir // '');
  my $dst_path = $cfg->{'templates'}{'html'} . '/' . ($subdir // '');

  my $tt = Template->new(
    'OUTPUT_PATH' => $dst_path,
    'INCLUDE_PATH' => [ $src_path, $cfg->{'templates'}{'include'} ],
    'RELATIVE' => 1
  );
  if(!ref($tt)) { die 'Failed to initialize Template Toolkit'; }

  #--- find the templates

  my @templates;
  if(! -d $src_path) { croak 'Non-existent path'; }
  opendir(my $dh, $src_path)
    or die "Could not open template directory '$src_path'";
  @templates = grep {
    /^.*\.tt$/
    && -f "$src_path/$_"
  } readdir($dh);
  closedir($dh);
  return if !@templates;

  #--- iterate over template files

  for my $template (@templates) {

  #--- iterate over supplied iteration values

    for my $val (@$iter_vals) {
      my $dest_file = $template;
      $dest_file =~ s/\.tt$//;

      # if the iteration values are defined, ie. not from the dummy list
      # then temporarily insert them into the user data

      if(defined $iter_var && defined $val) {
        $data->{$iter_var} = $val;
      }

      # if the iteration variable and template filename (without suffix)
      # match, then make the output filename be the iteration variable _value_,
      # For example if the template file is 'player.tt' and the iteration
      # variable is player = [ 'adeon', 'stth', 'raisse' ... ] then the
      # generated pages will be adeon.html, stth.html, raisse.html ...

      if(defined $iter_var && $dest_file eq $iter_var) {
        $dest_file = $val;
      }

      # otherwise, the output file will be named "value-template.html"

      elsif(defined $val) {
        $dest_file = "$val-$dest_file";
      }

      # now perform the template processing

      if(!$tt->process($template, $data, $dest_file . '.html')) {
        die $tt->error();
      }

      # remove temporary data

      if(defined $iter_var && defined $val) {
        delete $data->{$iter_var};
      }
    }
  }
}


#============================================================================
# Format the "realtime" xlogfile field
#============================================================================

sub format_duration
{
  my $realtime = shift;
  my ($d, $h, $m, $s) = (0,0,0,0);
  my $duration;

  $d = $realtime / 86400;
  $realtime %= 86400;

  $h = $realtime / 3600;
  $realtime %= 3600;

  $m = $realtime / 60;
  $realtime %= 60;

  $s = $realtime;

  $duration = sprintf("%s:%02s:%02s", $h, $m, $s);
  if($d) {
    $duration = sprintf("%s, %s:%02s:%02s", $d, $h, $m, $s);
  }

  return $duration;
}


#============================================================================
# Format the starttime/endtime xlogfile fileds.
#============================================================================

sub format_datetime
{
  my $time = shift;

  my @t = localtime($time);
  return sprintf("%04d-%02d-%02d %02d:%02d:%02d", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}


#============================================================================
# Display usage summary
#============================================================================

sub help
{
  print "Command-line options:\n";
  print "  --debug       debug mode\n";
  print "\n";
}



#============================================================================
#=== row consumers ==========================================================
#============================================================================

# These are functions that get to process every line of xlogfile as it's
# being read; they receive the hashref of the parsed xlogfile row as the
# argument.

{ #<<< start a new scope for row consumers

my $game_id = 0;
my $game_current_id;

#============================================================================
# This stores every game from the xlogfile to a list for later reference.
#============================================================================

push(@row_consumers, sub
{
  my $xrow = shift;

  #--- insert additional computed fields

  $xrow->{'_ncond'} = scalar(conduct($xrow->{'conduct'}));
  $xrow->{'_conds'} = join(' ', conduct($xrow->{'conduct'}));
  $xrow->{'_realtime'} = format_duration($xrow->{'realtime'});
  $xrow->{'_endtime'} = format_datetime($xrow->{'endtime'});

  #--- insert games into master list of all games

  $s{'games'}{'data'}{'all'}[$game_id] = { (%$xrow, '_id', $game_id) };
  $game_current_id = $game_id++;
});

#============================================================================
# This stores list of references of all winning games in chronological order.
#============================================================================

push(@row_consumers, sub
{
  my $xrow = shift;

  if(is_ascended($xrow)) {
    push(@{$s{'games'}{'data'}{'ascended'}}, $game_current_id);
  }
});

#============================================================================
# Record players' games
#============================================================================

push(@row_consumers, sub
{
  my $xrow = shift;
  my $plr_name = $xrow->{'name'};

  #--- if player sub-tree or the games list do not exist, instantiate it

  if(
    !exists $s{'players'}{'data'}{$plr_name}
    || !exists $s{'players'}{'data'}{$plr_name}{'games'}
  ) {
    $s{'players'}{'data'}{$plr_name}{'games'} = [];
    $s{'players'}{'data'}{$plr_name}{'cnt_games'} = 0;
    $s{'players'}{'data'}{$plr_name}{'cnt_ascensions'} = 0;
    $s{'players'}{'data'}{$plr_name}{'cnt_asc_turns'} = 0;
    $s{'players'}{'data'}{$plr_name}{'unique'}{'list'} = [];
    $s{'players'}{'data'}{$plr_name}{'unique'}{'when'} = undef;
  }

  #--- push new game into the list

  push(@{$s{'players'}{'data'}{$plr_name}{'games'}}, $game_current_id);

  #--- increment games played counter

  $s{'players'}{'data'}{$plr_name}{'cnt_games'}++;

  #--- increment games ascended counter

  if(is_ascended($xrow)) {
    $s{'players'}{'data'}{$plr_name}{'cnt_ascensions'}++;
    $s{'players'}{'data'}{$plr_name}{'cnt_asc_turns'} += $xrow->{'turns'};
  }

});

#============================================================================
# Recognition trophies recording, only single game ones, ie the "star"
# trophies
#============================================================================

push(@row_consumers, sub
{
  my $xrow = shift;
  my $plr_name = $xrow->{'name'};
  my $t = $s{'trophies'}{'recognition'};

  my @trophies = (
    [    1, 'iron'      ],
    [    2, 'copper'    ],
    [    4, 'brass'     ],
    [    8, 'steel'     ],
    [   16, 'bronze'    ],
    [   32, 'silver'    ],
    [   64, 'gold'      ],
    [  128, 'platinum'  ],
    [  256, 'dilithium' ],
    [  512, 'lead'      ],
    [ 1024, 'plastic'   ],
    [ 2048, 'zinc'      ],
  );

  for my $trophy (@trophies) {
    if(eval($xrow->{'achieve'}) & $trophy->[0]) {
      if(!exists($t->{$trophy->[1]})) {
        $t->{$trophy->[1]} = [ $plr_name ];
      } else {
        if(!grep { $_ eq $plr_name } @{$t->{$trophy->[1]}}) {
          push(@{$t->{$trophy->[1]}}, $plr_name);
        }
      }
    }
  }

});

#============================================================================
# Unique Deaths.
#============================================================================

push(@row_consumers, sub
{
  my $xrow = shift;
  my $plr_name = $xrow->{'name'};
  my $plr_data = $s{'players'}{'data'}{$plr_name};

  #--- iterate over rejection regexes, immediately exit on match

  for my $re (@{$cfg->{'unique'}{'death_no_list'}}) {
    return if $xrow->{'death'} =~ /$re/;
  }

  #--- iterate over accept regexes

  for(my $i = 0; $i < scalar(@{$cfg->{'unique'}{'death_yes_list'}}); $i++) {
    my $re = $cfg->{'unique'}{'death_yes_list'}[$i];
    if($xrow->{'death'} =~ /$re/) {

  #--- match found, see if we already have this recorded, if not, insert it

      if(!grep { $_ == $i } @{$plr_data->{'unique'}{'list'}}) {
        push(@{$plr_data->{'unique'}{'list'}}, $i);
        $plr_data->{'unique'}{'when'} = $xrow->{'endtime'};
      }

  #--- end the iteration

      last;
    }
  }

});

} #>>> end the scope of row consumers



#============================================================================
#=== global consumers =======================================================
#============================================================================

# These are functions that are called once the whole xlogfile is read in,
# which also means that the row consumers did their work. Note, that the
# order of their definition is important as some build on the output of the
# preceding ones.

#============================================================================
# Create list of player names ordered by number of ascensions. Ties are
# broken by ascension ratios (ie. players that took less games to achieve
# same win count are prefered).
#============================================================================

push(@glb_consumers, sub
{
  #--- shortcut for players-data subtree

  my $plr = $s{'players'}{'data'};

  #--- get list of ascending players

  my @plr_list = grep { ($plr->{$_}{'cnt_ascensions'} // 0) > 0 } keys %$plr;

  #--- sort the eligible players by number of ascensions

  my @plr_ordered = sort {
    if($plr->{$b}{'cnt_ascensions'} == $plr->{$a}{'cnt_ascensions'}) {
      $plr->{$a}{'cnt_games'} <=> $plr->{$b}{'cnt_games'}
    } else {
      $plr->{$b}{'cnt_ascensions'} <=> $plr->{$a}{'cnt_ascensions'}
    }
  } @plr_list;

  #--- store the result

  $s{'players'}{'meta'}{'ord_by_ascs'} = \@plr_ordered;

});

#============================================================================
# Create list of ascending games ordered by turncount (ascending).
#============================================================================

push(@glb_consumers, sub
{
  my $g = $s{'games'}{'data'}{'all'};
  my @sorted = sort {
    $g->[$a]{'turns'} <=> $g->[$b]{'turns'};
  } @{$s{'games'}{'data'}{'ascended'}};
  $s{'games'}{'data'}{'asc_by_turns'} = \@sorted;
});

#============================================================================
# Create list of ascending games ordered by duration (ascending).
#============================================================================

push(@glb_consumers, sub
{
  my $g = $s{'games'}{'data'}{'all'};
  my @sorted = sort {
    $g->[$a]{'realtime'} <=> $g->[$b]{'realtime'};
  } @{$s{'games'}{'data'}{'ascended'}};
  $s{'games'}{'data'}{'asc_by_duration'} = \@sorted;
});

#============================================================================
# Create list of ascending games ordered by score.
#============================================================================

push(@glb_consumers, sub
{
  my $g = $s{'games'}{'data'}{'all'};
  my @sorted = sort {
    $g->[$a]{'points'} <=> $g->[$b]{'points'};
  } @{$s{'games'}{'data'}{'ascended'}};
  $s{'games'}{'data'}{'asc_by_minscore'} = \@sorted;
  $s{'games'}{'data'}{'asc_by_maxscore'} = [ reverse @sorted ];
});

#============================================================================
# Create list of ascending games oredered by number of conducts, ties broken
# by who got there first.
#============================================================================

push(@glb_consumers, sub
{
  my $g = $s{'games'}{'data'}{'all'};
  my @sorted = sort {
    my ($cond_a, $cond_b) = (
      $g->[$a]{'_ncond'},
      $g->[$b]{'_ncond'}
    );
    if($cond_a == $cond_b) {
      return $g->[$a]{'endtime'} <=> $g->[$b]{'endtime'}
    }
    return $cond_b <=> $cond_a;
  } @{$s{'games'}{'data'}{'ascended'}};
  $s{'games'}{'data'}{'asc_by_conducts'} = \@sorted;
});


#============================================================================
# Most extinct monsters in a single game (doesn't need to be an ascension),
# only top3 retained.
#============================================================================

push(@glb_consumers, sub
{
  my $g = $s{'games'}{'data'}{'all'};
  my @sorted = sort {
    if($b->{'extinctions'} == $a->{'extinctions'}) {
      return $a->{'endtime'} <=> $b->{'endtime'};
    }
    $b->{'extinctions'} <=> $a->{'extinctions'}
  } @$g;
  $s{'games'}{'data'}{'games_by_exts'} = [
    map { $_->{'_id'} } @sorted[0..2]
  ];
});


#============================================================================
# Most killed monsters in a single game (doesn't need to be an ascension),
# only top3 retained.
#============================================================================

push(@glb_consumers, sub
{
  my $g = $s{'games'}{'data'}{'all'};
  my @sorted = sort {
    if($b->{'kills120'} == $a->{'kills120'}) {
      return $a->{'endtime'} <=> $b->{'endtime'};
    }
    $b->{'kills120'} <=> $a->{'kills120'}
  } @$g;
  $s{'games'}{'data'}{'games_by_kills'} = [
    map { $_->{'_id'} } @sorted[0..2]
  ];
});


#============================================================================
# Minor trophies, ie. highest scoring ascension for each role.
#============================================================================

push(@glb_consumers, sub
{
  #--- data sources

  my $ascs = $s{'games'}{'data'}{'asc_by_maxscore'};
  my $idx = $s{'games'}{'data'}{'all'};

  #--- auxiliary data for the templates

  $s{'aux'}{'roles'} = [
    'Arc', 'Bar', 'Cav', 'Hea', 'Kni', 'Mon', 'Pri',
    'Ran', 'Rog', 'Sam', 'Tou', 'Val', 'Wiz'
  ];

  #--- iterate over all roles

  for my $role (@{$s{'aux'}{'roles'}}) {

  #--- find three top scoring ascensions per role

    my $counter = 0;
    $s{'games'}{'data'}{'top_by_role'}{$role} = [];
    for my $asc (@$ascs) {
      if($idx->[$asc]{'role'} eq $role) {
        push(@{$s{'games'}{'data'}{'top_by_role'}{$role}}, $asc);
        $counter++;
      }
      last if $counter > 2;
    }
  }
});

#============================================================================
# This is just emplacing some ancillary info for templates.
#============================================================================

push(@glb_consumers, sub
{

  $s{'aux'}{'trophies'}{'recognition'}{'ord'} = [
    qw(plastic lead iron zinc copper brass steel bronze silver gold platinum
       dilithium birdie doubletop hattrick grandslam fullmonty)
  ];

  $s{'aux'}{'trophies'}{'recognition'}{'data'} = {
    plastic => 'Plastic Star',
    lead => 'Lead Star',
    iron  => 'Iron Star',
    zinc => 'Zinc Star',
    copper => 'Copper Star',
    brass => 'Brass Star',
    steel => 'Steel Star',
    bronze => 'Bronze Star',
    silver => 'Silver Star',
    gold => 'Gold Star',
    platinum => 'Platinum Star',
    dilithium => 'Dilithium Star',
    birdie => 'Birdie',
    doubletop => 'Double Top',
    hattrick => 'Hat Trick',
    grandslam => 'Grand Slam',
    fullmonty => 'Full Monty'
  };

});

#============================================================================
# This compiles multi-ascension Recognition Trophies.
#============================================================================

push(@glb_consumers, sub
{
  my @players = keys %{$s{'players'}{'data'}};
  my @trophies = (qw(birdie doubletop hattrick grandslam fullmonty));
  my %track;
  my %temp;

  #--- iterate over all players

  for my $plr (@players) {

  #--- iterate over trophies

    for my $tr (@trophies) {

  #--- get trophies trackers

      $track{$tr} = trophy_track($tr, 0);
      $track{"${tr}_wbo"} = trophy_track($tr, 1);

  #--- iterate over player's games

      for my $g (@{$s{'players'}{'data'}{$plr}{'games'}}) {
        $track{$tr}->($g);
        $track{"${tr}_wbo"}->($g);
      }

  #--- save result

      if(my $g = $track{$tr}->()) {
        push(@{$temp{$tr}}, { name => $plr, ord => $g->[0]});
      }
      if(my $g = $track{"${tr}_wbo"}->()) {
        push(@{$temp{"${tr}_wbo"}}, { name => $plr, ord => $g->[0]});
      }
    }
  }

  #--- sort the resulting data

  for my $tr (@trophies) {

    if($temp{$tr}) {
      $s{'trophies'}{'recognition'}{$tr} = [
        map { $_->{'name'} }
        sort { $a->{'ord'} <=> $b->{'ord'} } @{$temp{$tr}}
      ];
    }

    if($temp{"${tr}_wbo"}) {
      $s{'trophies'}{'recognition'}{"${tr}_wbo"} = [
        map { $_->{'name'} }
        sort { $a->{'ord'} <=> $b->{'ord'} } @{$temp{"${tr}_wbo"}}
      ];
    }

  }

});


#============================================================================
# Best of 13
#============================================================================

push(@glb_consumers, sub
{
  #--- sortcut for players data subtree

  my $plr_data = $s{'players'}{'data'};

  #--- get list of ascending players (no need to bother with non-ascenders)

  my @plr_list = grep {
    ($plr_data->{$_}{'cnt_ascensions'} // 0) > 0
  } keys %$plr_data;

  #--- iterate over players

  for my $plr (sort @plr_list) {
    my $games = $plr_data->{$plr}{'games'};

  #--- if player has 13 games or less, there's no need for sequential scan

    if(scalar(@$games) <= 13) {
      $plr_data->{$plr}{'best13'} = combo_ascends_nrepeat(@$games);
      next;
    }

  #--- otherwise we need to iterate

    my $best_of_13 = { cnt => 0, games => [], when => undef };
    for(my $i = 0; $i < scalar(@$games)-13; $i++) {
      my $cur_13 = combo_ascends_nrepeat(@$games[$i..$i+13]);
      if($cur_13->{'cnt'} > $best_of_13->{'cnt'}) {
        $best_of_13 = $cur_13;
      }
    }
    $plr_data->{$plr}{'best13'} = $best_of_13;

  }

  #--- compile the best of 13 list

  $s{'trophies'}{'best13'} = [ sort {
    my $pa = $plr_data->{$a}{'best13'};
    my $pb = $plr_data->{$b}{'best13'};

    if($pa->{'cnt'} == $pb->{'cnt'}) {
      return $pa->{'when'} <=> $pb->{'when'}
    }
    $pb->{'cnt'} <=> $pa->{'cnt'}
  } @plr_list ];
});

#============================================================================
# Unique Deaths (compiling final list, the data collection is already done
# by a row consumer).
#============================================================================

push(@glb_consumers, sub
{
  my $plr_data = $s{'players'}{'data'};

  $s{'trophies'}{'unique'} = [ sort {

    my $na = scalar(@{$plr_data->{$a}{'unique'}{'list'}});
    my $nb = scalar(@{$plr_data->{$b}{'unique'}{'list'}});
    if($na == $nb) {
      return $plr_data->{$a}{'unique'}{'when'} <=> $plr_data->{$b}{'unique'}{'when'};
    }
    $nb <=> $na;
  } grep { $plr_data->{$_}{'unique'}{'when'} } keys %$plr_data ];
});

#============================================================================
# Challenge Trophies. Please note, that only players who completed at least
# one game are considered, this is for technical reasons -- it's fairly
# awkward to implement provisions for players with no games.
#============================================================================

push(@glb_consumers, sub
{
  my $p = $s{'players'}{'data'};

  #--- exit if no challenge list is configured

  return if !exists $cfg->{'challenges'}{'list'};

  #--- save ancillary data for templates

  $s{'aux'}{'trophies'}{'challenges'}{'ord'} = [
    sort keys %{$cfg->{'challenges'}{'list'}}
  ];
  $s{'aux'}{'trophies'}{'challenges'}{'data'} = $cfg->{'challenges'}{'list'};

  #--- get list of eligible players

  my @players = grep {
    exists $s{'players'}{'data'}{$_}{'games'}
    && $s{'players'}{'data'}{$_}{'challenges'}
  } keys %{$s{'players'}{'data'}};

  #--- exit if no eligible players

  return if !@players;

  #--- compile challenges data

  return if !exists $cfg->{'challenges'}{'list'};
  for my $chal (keys %{$cfg->{'challenges'}{'list'}}) {

    # find players who completed the challenge
    my @lst = grep {
      exists $p->{$_}{'challenges'}{$chal}
      && $p->{$_}{'challenges'}{$chal}{'status'} eq 'success'
    } @players;

    # go to next challenge if no successful players found
    next if !@lst;

    # sort the successful players by completion date
    $s{'trophies'}{'challenges'}{$chal} = [ sort {
      $p->{$a}{'challenges'}{$chal}{'when'}
      <=>
      $p->{$b}{'challenges'}{$chal}{'when'}
    } @lst ];
  }

});

#============================================================================
# This section goes over Recognition Trophies and for each player removes all
# but the highest trophy. This is done separately for non-WBO and WBO
# trophies
#============================================================================

push(@glb_consumers, sub
{
  #--- get list of players that have at least the Plastic Star

  my @players = keys %{$s{'players'}{'data'}};

  #--- get list of Recognition Trophies, in descending order

  my $f = 1;
  my @trophies = reverse @{$s{'aux'}{'trophies'}{'recognition'}{'ord'}};
  my @trophies_wbo = map { $_ . '_wbo' } grep {
    if($_ eq 'dilithium') { $f = 0; }
    $f;
  } @trophies;

  #--- iterate over players

  for my $plr (@players) {

  #--- find the highest trophy and then remove all the lower ones;

    for my $trophies_lst (\@trophies, \@trophies_wbo) {
      my $remove = 0;
      for my $trophy (@$trophies_lst) {
        if($remove) {
          $s{'trophies'}{'recognition'}{$trophy} = [ grep {
            $_ ne $plr
          } @{$s{'trophies'}{'recognition'}{$trophy}} ];
          next;
        }
        if(grep { $_ eq $plr } @{$s{'trophies'}{'recognition'}{$trophy}}) {
          $remove = 1;
        }
      }
    }
  }

});

#============================================================================
# Player scoring for use in the Best In Show trophy
#============================================================================

push(@glb_consumers, sub
{
  no integer;

  #--- prepare utility function for pushing scoring info

  my $score = sub {
    my ($plr, $trophy, $data, $adj) = @_;
    my $sc_trophy = $trophy;
    $sc_trophy =~ s/_wbo$//;

    #--- adjustment for the score, this is here so that challenge can
    #--- give different amount of points the first players and the rest

    if(!defined($adj)) { $adj = 1; }

    #--- verify necessary config and data exist

    if(
      !exists $cfg->{'scoring'}{$sc_trophy}
      || !exists $s{'players'}{'data'}{$plr}
    ) {
      die "Scoring info not found for trophy '$trophy' or non-existing player '$plr'";
    }

    #--- insert the scoring entry

    push(
      @{$s{'players'}{'data'}{$plr}{'scoring'}},
      [ $trophy, $cfg->{'scoring'}{$sc_trophy} * $adj, $data ]
    );
  };

  #--- ensure the config exists

  if(!exists $cfg->{'scoring'}) { die 'No config for scoring'; }

  #--- list of players

  my @players = keys %{$s{'players'}{'data'}};

  #--- Best Of 13

  if(
    exists $s{'trophies'}{'best13'}
    && @{$s{'trophies'}{'best13'}}
  ) {
    my $plr = $s{'trophies'}{'best13'}[0];
    $score->($plr, 'best13');
  }

  #--- Most Ascensions

  if(
    exists $s{'players'}{'meta'}{'ord_by_ascs'}
    && @{$s{'players'}{'meta'}{'ord_by_ascs'}}
  ) {
    $score->($s{'players'}{'meta'}{'ord_by_ascs'}[0], 'mostascs');
  }

  #--- Fastest Ascension: Gametime

  if(
    exists $s{'games'}{'data'}{'asc_by_turns'}
    && @{$s{'games'}{'data'}{'asc_by_turns'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_turns'}[0]);
    $score->($g->{'name'}, 'mingametime');
  }

  #--- Fastest Ascension: Realtime

  if(
    exists $s{'games'}{'data'}{'asc_by_duration'}
    && @{$s{'games'}{'data'}{'asc_by_duration'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_duration'}[0]);
    $score->($g->{'name'}, 'minrealtime');
  }

  #--- Lowest Scoring Ascension

  if(
    exists $s{'games'}{'data'}{'asc_by_minscore'}
    && @{$s{'games'}{'data'}{'asc_by_minscore'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_minscore'}[0]);
    $score->($g->{'name'}, 'minscore');
  }

  #--- First Ascension

  if(
    exists $s{'games'}{'data'}{'ascended'}
    && @{$s{'games'}{'data'}{'ascended'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'ascended'}[0]);
    $score->($g->{'name'}, 'firstasc');
  }

  #--- Best Behaved Ascension

  if(
    exists $s{'games'}{'data'}{'asc_by_conducts'}
    && @{$s{'games'}{'data'}{'asc_by_conducts'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_conducts'}[0]);
    $score->($g->{'name'}, 'bestconduct');
  }

  #--- Most Unique Deaths

  if(
    exists $s{'trophies'}{'unique'}
    && @{$s{'trophies'}{'unique'}}
  ) {
    $score->($s{'trophies'}{'unique'}[0], 'unique');
  }

  #--- Recognition Trophies

  my @trophies = @{$s{'aux'}{'trophies'}{'recognition'}{'ord'}};

  for my $plr (@players) {
    for my $trophy (@trophies) {
      # without bells on
      if(
        grep { $_ eq $plr } @{$s{'trophies'}{'recognition'}{$trophy}}
      ) {
        $score->($plr, $trophy);
      }
      # with bells on
      if(
        exists $s{'trophies'}{'recognition'}{$trophy . '_wbo'}
        && grep { $_ eq $plr } @{$s{'trophies'}{'recognition'}{$trophy . '_wbo'}}
      ) {
        $score->($plr, $trophy . '_wbo');
      }
    }
  }

  #--- Minor Trophies (per-role maxscores)

  my $roles = $s{'aux'}{'roles'};

  for my $role (@$roles) {
    if(@{$s{'games'}{'data'}{'top_by_role'}{$role}}) {
      my $g = get_xrows($s{'games'}{'data'}{'top_by_role'}{$role}[0]);
      $score->($g->{'name'}, 'minor', { 'role' => $role });
    }
  }

  #--- Who Wants To Be A Killionaire?

  if(
    exists $s{'games'}{'data'}{'games_by_kills'}
    && @{$s{'games'}{'data'}{'games_by_kills'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'games_by_kills'}[0]);
    $score->($g->{'name'}, 'killionaire');
  }

  #--- Basic Extinct

  if(
    exists $s{'games'}{'data'}{'games_by_exts'}
    && @{$s{'games'}{'data'}{'games_by_exts'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'games_by_exts'}[0]);
    $score->($g->{'name'}, 'extinct');
  }

  #--- Challenge Trophies (only the first player gets full score,
  #--- the rest gets only half)

  for my $chal (keys %{$s{'trophies'}{'challenges'}}) {
    if(@{$s{'trophies'}{'challenges'}{$chal}}) {
      my $adj = 1;
      for my $plr (@{$s{'trophies'}{'challenges'}{$chal}}) {
        $score->($plr, 'challenge', undef, $adj);
        $adj = 0.5;
      }
    }
  }
});

#============================================================================
# Compile the Best In Show summary scores.
#============================================================================

push(@glb_consumers, sub
{
  no integer;

  for my $clan (keys %{$s{'clans'}}) {
    my $score = 0;
    my @breakdown;
    for my $plr (@{$s{'clans'}{$clan}{'members'}}) {
      if(exists $s{'players'}{'data'}{$plr}{'scoring'}) {
        for my $e (@{$s{'players'}{'data'}{$plr}{'scoring'}}) {
          $score += $e->[1];
          push(@breakdown, [ $plr, @$e ]);
        }
      }
    }
    $s{'clans'}{$clan}{'bestinshow'} = {
      'score' => $score,
      'breakdown' => [ sort {
        if($a->[0] eq $b->[0]) {
          return $b->[2] <=> $a->[2];
        }
        $a->[0] cmp $b->[0];
      } @breakdown ]
    };
  }

  $s{'trophies'}{'bestinshow'} = [ sort {
    $s{'clans'}{$b}{'bestinshow'}{'score'}
    <=>
    $s{'clans'}{$a}{'bestinshow'}{'score'}
  } keys %{$s{'clans'}} ];
});



#============================================================================
#===================  _  ====================================================
#===  _ __ ___   __ _(_)_ __  ===============================================
#=== | '_ ` _ \ / _` | | '_ \  ==============================================
#=== | | | | | | (_| | | | | | ==============================================
#=== |_| |_| |_|\__,_|_|_| |_| ==============================================
#===                           ==============================================
#============================================================================
#============================================================================

#--- process command-line options

my (
  $cmd_debug
);

if(!GetOptions(
  'debug' => \$cmd_debug,
)) {
  help();
  exit(1);
}

#--- check/create lock file

if(-f $lockfile) {
  print "Lockfile $lockfile exists, exiting.";
  exit(1);
}

open(F, '>', $lockfile) || die "Failed to create lockfile $lockfile";
print F $$, "\n";
close(F);

#--- read the unique deaths filter lists

for my $list (qw(no yes)) {
  if(exists $cfg->{'unique'}{"death_$list"}) {
    open(F, '<', $cfg->{'unique'}{"death_$list"})
      || die "Cannot open filter file (death_$list)";
    while(my $l = <F>) {
      chomp $l;
      push(@{$cfg->{'unique'}{"death_${list}_list"}}, qr/^$l/);
    }
    close(F);
  }
}

#--- read the clan information

if(exists $cfg->{'clandb'} && -f $cfg->{'clandb'}) {
  my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $cfg->{'clandb'},
    undef, undef
  );
  if(!ref($dbh)) {
    die "Failed to open clan database at " . $cfg->{'clandb'};
  }
  my $sth = $dbh->prepare(
    'SELECT players.name AS name, clans.name AS clan, clan_admin ' .
    'FROM players JOIN clans USING (clans_i)'
  );
  my $r = $sth->execute();
  if(!$r) {
    die sprintf('Failed to query clan database (%s)', $sth->errstr());
  }
  while(my $h = $sth->fetchrow_hashref) {
    push(@{$s{'clans'}{ $h->{'clan'} }{'members'}}, $h->{'name'});
    push(@{$s{'clans'}{ $h->{'clan'} }{'admins'}}, $h->{'name'})
      if $h->{'clan_admin'};
  }
}

#--- read challenge status

if($cfg->{'challenges'}{'status'}) {
  open(F, '<', $cfg->{'challenges'}{'status'})
    or die "Could not open challenge status file";
  while(my $l = <F>) {
    chomp($l);
    my @chal = split(/:/, $l);
    $s{'players'}{'data'}{$chal[2]}{'challenges'}{lc($chal[1])} = {
      'when' => $chal[0],
      'status' => lc($chal[3])
    }
  }
  close(F);
}

#--- read all the xlogfiles into memory

my @merged_xlog;
for my $src (keys %{$cfg->{'sources'}}) {
  open(my $xlog, '<', $cfg->{'sources'}{$src}{'xlogfile'})
    or die "Could not open the xlogfile";
  while(my $l = <$xlog>) {
    chomp($l);
    my $xrow = parse_log($l);
    $xrow->{'_src'} = $src;
    push(@merged_xlog, $xrow);
  }
  close($xlog);
}

#--- invoke row consumers

for my $xrow (sort { $a->{'endtime'} <=> $b->{'endtime'} } @merged_xlog) {
  for my $consumer (@row_consumers) {
    $consumer->($xrow);
  }
}
undef @merged_xlog;

#--- invoke global consumers

for my $consumer (@glb_consumers) {
  $consumer->();
}

#--- debug: save the compiled scoreboard data as JSON

if($cmd_debug) {
  open(JS, '>', "debug.scoreboard.$$") or die;
  print JS JSON->new->pretty(1)->encode(\%s), "\n";
  close(JS);
}

#--- template processing

process_templates(undef, \%s);
process_templates('clans', \%s, 'clan', [ keys %{$s{'clans'}} ]);
process_templates('players', \%s, 'player', [ keys %{$s{'players'}{'data'}} ]);

#--- release lock file

unlink($lockfile);
