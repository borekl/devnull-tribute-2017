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
use Template::Directive;
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
  $Template::Directive::WHILE_MAX = 100000;

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

  my @t = gmtime($time);
  return sprintf("%04d-%02d-%02d %02d:%02d", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1]);
}


#============================================================================
# URL substitution for dumplogs.
#============================================================================

sub url_substitute
{
  my (
    $xrow,
    $dump
  ) = @_;

  croak 'Undefined argument' if !defined $xrow;
  $xrow = get_xrows($xrow);

  my $r_username = $xrow->{'name'};
  my $r_uinitial = substr($xrow->{'name'}, 0, 1);
  my $r_starttime = $xrow->{'starttime'};

  $dump =~ s/%u/$r_username/g;
  $dump =~ s/%U/$r_uinitial/g;
  $dump =~ s/%s/$r_starttime/g;

  return $dump;
}


#============================================================================
# Display usage summary
#============================================================================

sub help
{
  print "Command-line options:\n";
  print "  --debug           debug mode\n";
  print "  --noping          disable pinging source servers\n";
  print "  --trophies[=FILE] save trophies file (trophies.json by default)\n";
  print "  --coalesce=FILE   save merged xlogfile\n";
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
  $xrow->{'_asc'} = is_ascended($xrow) ? JSON::true : JSON::false;
  $xrow->{'_id'} = $game_id;

  #--- link to dumpfile (if defined)

  if($cfg->{'sources'}{$xrow->{'_src'}}{'dumplog'} // undef) {
    $xrow->{'_dump'} = url_substitute(
      $xrow, $cfg->{'sources'}{$xrow->{'_src'}}{'dumplog'}
    );
  }

  #--- detect scummed games

  $xrow->{'_scum'} = 0;
  if(exists $cfg->{'scum'}) {
    if(exists $cfg->{'scum'}{'minturns'}) {
      if($xrow->{'turns'} <= $cfg->{'scum'}{'minturns'}) {
        $xrow->{'_scum'} = 1;
      }
    }
    if(exists $cfg->{'scum'}{'minquitturns'}) {
      if(
        $xrow->{'turns'} <= $cfg->{'scum'}{'minquitturns'}
        && ( $xrow->{'death'} eq 'quit' || $xrow->{'death'} eq 'escape' )
      ) {
        $xrow->{'_scum'} = 1;
      }
    }
  }

  #--- insert games into master list of all games

  $s{'games'}{'data'}{'all'}[$game_id] = $xrow;
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
    $s{'players'}{'data'}{$plr_name} = {
      'challenges'     => $s{'players'}{'data'}{$plr_name}{'challenges'} // undef,
      'games'          => [],
      'cnt_games'      => 0,
      'cnt_ascensions' => 0,
      'cnt_asc_turns'  => 0,
      'unique'         => { 'list' => [], 'when' => undef },
      'last_asc'       => undef,
      'maxlvl'         => 0,
      'maxlvl_game'    => undef,
      'score'          => 0,
      'clan'           => do {
                            my ($clan) = grep {
                              grep {
                                $_ eq $plr_name;
                              } @{$s{'clans'}{$_}{'members'}};
                            } keys %{$s{'clans'}};
                            $clan;
                          },
    };
  }

  #--- push new game into the list

  push(@{$s{'players'}{'data'}{$plr_name}{'games'}}, $game_current_id);

  #--- increment games played counter

  $s{'players'}{'data'}{$plr_name}{'cnt_games'}++;

  #--- increment games ascended counter, store last ascension

  if(is_ascended($xrow)) {
    $s{'players'}{'data'}{$plr_name}{'cnt_ascensions'}++;
    $s{'players'}{'data'}{$plr_name}{'cnt_asc_turns'} += $xrow->{'turns'};
    $s{'players'}{'data'}{$plr_name}{'last_asc'} = $xrow->{'_id'};

  #--- update per-player maxconducts

    if(!defined $s{'players'}{'data'}{$plr_name}{'maxconducts'}) {
      $s{'players'}{'data'}{$plr_name}{'maxconducts'} = 0;
    }
    if(($s{'players'}{'data'}{$plr_name}{'maxconducts'} // 0) < $xrow->{'_ncond'}) {
      $s{'players'}{'data'}{$plr_name}{'maxconducts'} = $xrow->{'_ncond'};
    }
  }

  #--- update per-player maxlvl

  if($s{'players'}{'data'}{$plr_name}{'maxlvl'} < $xrow->{'maxlvl'}) {
    $s{'players'}{'data'}{$plr_name}{'maxlvl'} = $xrow->{'maxlvl'};
    $s{'players'}{'data'}{$plr_name}{'maxlvl_game'} = $game_current_id;
  }

  #--- update player's total score

  $s{'players'}{'data'}{$plr_name}{'score'} += $xrow->{'points'};

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
    [  512, 'plastic'   ],
    [ 1024, 'lead'      ],
    [ 2048, 'zinc'      ],
  );

  #--- iterate over above trophies

  for my $trophy (@trophies) {
    if(eval($xrow->{'achieve'}) & $trophy->[0]) {

  #--- add player to trophies.recognition.$TROPHY

      if(!exists($t->{$trophy->[1]})) {
        $t->{$trophy->[1]} = [ $plr_name ];
      } else {
        if(!grep { $_ eq $plr_name } @{$t->{$trophy->[1]}}) {
          push(@{$t->{$trophy->[1]}}, $plr_name);
        }
      }

  #--- save trophy time reference

      if(
        !exists $s{'players'}{'data'}{$plr_name}{'recognition'}{$trophy->[1]}
      ) {
        $s{'players'}{'data'}{$plr_name}{'recognition'}{$trophy->[1]}
        = $xrow->{'endtime'};
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

  for my $re (@{$cfg->{'unique'}{'compiled'}{'death_no_list'}}) {
    return if $xrow->{'death'} =~ /$re/;
  }

  #--- iterate over accept regexes

  for(my $i = 0; $i < scalar(@{$cfg->{'unique'}{'compiled'}{'death_yes_list'}}); $i++) {
    my $re = $cfg->{'unique'}{'compiled'}{'death_yes_list'}[$i];
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
# broken by endtime (ie. "who got there first").
#============================================================================

push(@glb_consumers, sub
{
  #--- shortcut for players-data subtree

  my $plr = $s{'players'}{'data'};

  #--- get list of all players; we are excluding players that do not have
  #--- any completed games; these players are not properly instantiated and
  #--- arise as being created by reading challenges status file

  my @plr_list = grep {
    exists $plr->{$_}{'cnt_ascensions'}
  } keys %{$s{'players'}{'data'}};

  #--- sort the eligible players by number of ascensions (with endtime
  #--- as a tie breaker); non-ascending players are sorted by maxlvl with
  #--- ties broken by endtime of the game achieving the maxlvl

  my @plr_ordered = sort {

    # both players have the same number of ascensions; this can also mean that
    # neither player has ascended

    if($plr->{$a}{'cnt_ascensions'} == $plr->{$b}{'cnt_ascensions'}) {

    # if both players have the same number of ascensions (one or more), then
    # break ties by endttime of the last ascension

      if($plr->{$a}{'cnt_ascensions'}) {
        return
          get_xrows($plr->{$a}{'last_asc'})->{'endtime'}
          <=>
          get_xrows($plr->{$b}{'last_asc'})->{'endtime'};
      }

    # if both players have no ascensions, then try to break the tie with
    # their maximum achieved level (from the "maxlvl" xlogfile field);
    # if it is tied too, then use endtime of the game it was achieved with

      elsif($plr->{$a}{'maxlvl'} == $plr->{$b}{'maxlvl'}) {
        return
          get_xrows($plr->{$a}{'maxlvl_game'})->{'endtime'}
          <=>
          get_xrows($plr->{$b}{'maxlvl_game'})->{'endtime'}
      } else {
        return $plr->{$b}{'maxlvl'} <=> $plr->{$a}{'maxlvl'};
      }

    # the players have different number of ascensions, so sort by them only

    } else {
      $plr->{$b}{'cnt_ascensions'} <=> $plr->{$a}{'cnt_ascensions'};
    }

  } @plr_list;

  #--- store the results

  $s{'players'}{'meta'}{'ord_by_ascs_all'} = \@plr_ordered;
  $s{'players'}{'meta'}{'ord_by_ascs'} = [
    grep { $plr->{$_}{'cnt_ascensions'} } @plr_ordered
  ];

});

#============================================================================
# Create list of ascending games ordered by turncount (ascending).
#============================================================================

push(@glb_consumers, sub
{
  my $g = $s{'games'}{'data'}{'all'};
  my @sorted = sort {
    $g->[$a]{'turns'} == $g->[$b]{'turns'} ?
    $g->[$a]{'endtime'} <=> $g->[$b]{'endtime'} :
    $g->[$a]{'turns'} <=> $g->[$b]{'turns'}
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
    $g->[$a]{'realtime'} == $g->[$b]{'realtime'} ?
    $g->[$a]{'endtime'} <=> $g->[$b]{'endtime'} :
    $g->[$a]{'realtime'} <=> $g->[$b]{'realtime'}
  } @{$s{'games'}{'data'}{'ascended'}};

  $s{'games'}{'data'}{'asc_by_duration'} = \@sorted;
});

#============================================================================
# Create list of games ordered by score.
#============================================================================

push(@glb_consumers, sub
{
  my $g = $s{'games'}{'data'}{'all'};

  my @sorted_min = sort {
    $g->[$a]{'points'} == $g->[$b]{'points'} ?
    $g->[$a]{'endtime'} == $g->[$b]{'endtime'} :
    $g->[$a]{'points'} <=> $g->[$b]{'points'}
  } @{$s{'games'}{'data'}{'ascended'}};

  my @sorted_max = sort {
    $g->[$a]{'points'} == $g->[$b]{'points'} ?
    $g->[$a]{'endtime'} == $g->[$b]{'endtime'} :
    $g->[$b]{'points'} <=> $g->[$a]{'points'}
  } @{$s{'games'}{'data'}{'ascended'}};

  my @sorted_games_max =
    map {
      $_->{'_id'}
    } sort {
      $a->{'points'} == $b->{'points'} ?
      $a->{'endtime'} == $b->{'endtime'} :
      $b->{'points'} <=> $a->{'points'}
    } @{$s{'games'}{'data'}{'all'}};

  $s{'games'}{'data'}{'asc_by_minscore'} = \@sorted_min;
  $s{'games'}{'data'}{'asc_by_maxscore'} = \@sorted_max;
  $s{'games'}{'data'}{'games_by_maxscore'} = \@sorted_games_max;
});

#============================================================================
# Create list of ascending games ordered by number of conducts, ties broken
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
  my @sorted =
  grep { $_->{'extinctions'} > 0 }  # only games with actual extinctions
  sort {
    $a->{'extinctions'} == $b->{'extinctions'} ?
    $a->{'endtime'} <=> $b->{'endtime'} :
    $b->{'extinctions'} <=> $a->{'extinctions'};
  } @{$s{'games'}{'data'}{'all'}};

  # store only game ids, not actual rows; remove any undefined elements
  # that may arise from the array slice, that only preserves top three
  # results

  $s{'games'}{'data'}{'games_by_exts'} = [
    map {
      defined $_ ? $_->{'_id'} : ()
    } @sorted[0..2]
  ];
});


#============================================================================
# Most killed monsters in a single game (doesn't need to be an ascension),
# only top3 retained.
#============================================================================

push(@glb_consumers, sub
{
  my @sorted =
  grep { $_->{'kills120'} > 0 }  # only games with actual kills
  sort {
    $a->{'kills120'} == $b->{'kills120'} ?
    $a->{'endtime'} <=> $b->{'endtime'} :
    $b->{'kills120'} <=> $a->{'kills120'};
  } @{$s{'games'}{'data'}{'all'}};

  # store only game ids, not actual rows; remove any undefined elements
  # that may arise from the array slice, that only preserves top three
  # results

  if(@sorted) {
    $s{'games'}{'data'}{'games_by_kills'} = [
      map {
        defined $_ ? $_->{'_id'} : ()
      } @sorted[0..2]
    ];
  }
});


#============================================================================
# Minor trophies, ie. highest scoring games for each role.
#============================================================================

push(@glb_consumers, sub
{
  #--- data sources

  my $games = $s{'games'}{'data'}{'games_by_maxscore'};
  my $idx = $s{'games'}{'data'}{'all'};

  #--- iterate over all roles

  for my $role (@{$cfg->{'roles'}}) {

  #--- find three top scoring games per role

    my $counter = 0;
    $s{'games'}{'data'}{'top_by_role'}{$role} = [];
    for my $game (@$games) {
      if($idx->[$game]{'role'} eq $role) {
        push(@{$s{'games'}{'data'}{'top_by_role'}{$role}}, $game);
        $counter++;
      }
      last if $counter > 2;
    }
  }
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

  #--- save trophies' time references into player data

  for my $tr (keys %temp) {
    for my $entry (@{$temp{$tr}}) {
      $s{'players'}{'data'}{$entry->{'name'}}{'recognition'}{$tr}
      = get_xrows($entry->{'ord'})->{'endtime'};
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
    for(my $i = 0; $i <= scalar(@$games)-13; $i++) {
      my $cur_13 = combo_ascends_nrepeat(@$games[$i..$i+12]);
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

  #--- get list of eligible players

  my @players = grep {
    exists $s{'players'}{'data'}{$_}{'games'}
    && $s{'players'}{'data'}{$_}{'challenges'}
  } keys %{$s{'players'}{'data'}};

  #--- exit if no eligible players

  return if !@players;

  #--- compile challenges data

  for my $chal (@{$cfg->{'trophies'}{'ord'}{'challenges'}}) {

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
  my @trophies = reverse @{$cfg->{'trophies'}{'ord'}{'recognition'}};
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

  #--- prepare utility function for pushing scoring info --------------------

  my $score = sub {
    my (
      $plr,     # 1. player name
      $trophy,  # 2. trophy name
      $data,    # 3. (opt) trophy-specific data
      $adj,     # 4. (opt) score adjustment factor (for challenges)
      $when     # 5. time reference
    ) = @_;
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
      [
        $trophy,                               # 0. trophy name
        $cfg->{'scoring'}{$sc_trophy} * $adj,  # 1. score
        $data,                                 # 2. additional data
        $when                                  # 3. timestamp
      ]
    );
  };

  #--------------------------------------------------------------------------

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
    my $when = $s{'players'}{'data'}{$plr}{'best13'}{'when'};
    $score->($plr, 'best13', undef, undef, $when);
  }

  #--- Most Ascensions

  if(
    exists $s{'players'}{'meta'}{'ord_by_ascs'}
    && @{$s{'players'}{'meta'}{'ord_by_ascs'}}
  ) {
    my $plr = $s{'players'}{'meta'}{'ord_by_ascs'}[0];
    my $when = get_xrows(
      $s{'players'}{'data'}{$plr}{'last_asc'}
    )->{'endtime'};
    $score->($plr, 'mostascs', undef, undef, $when);
  }

  #--- Fastest Ascension: Gametime

  if(
    exists $s{'games'}{'data'}{'asc_by_turns'}
    && @{$s{'games'}{'data'}{'asc_by_turns'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_turns'}[0]);
    my $plr = $g->{'name'};
    my $when = $g->{'endtime'};
    $score->($plr, 'mingametime', undef, undef, $when);
  }

  #--- Fastest Ascension: Realtime

  if(
    exists $s{'games'}{'data'}{'asc_by_duration'}
    && @{$s{'games'}{'data'}{'asc_by_duration'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_duration'}[0]);
    my $plr = $g->{'name'};
    my $when = $g->{'endtime'};
    $score->($plr, 'minrealtime', undef, undef, $when);
  }

  #--- Lowest Scoring Ascension

  if(
    exists $s{'games'}{'data'}{'asc_by_minscore'}
    && @{$s{'games'}{'data'}{'asc_by_minscore'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_minscore'}[0]);
    my $plr = $g->{'name'};
    my $when = $g->{'endtime'};
    $score->($plr, 'minscore', undef, undef, $when);
  }

  #--- Highest Scoring Ascension

  if(
    exists $s{'games'}{'data'}{'asc_by_maxscore'}
    && @{$s{'games'}{'data'}{'asc_by_maxscore'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_maxscore'}[0]);
    my $plr = $g->{'name'};
    my $when = $g->{'endtime'};
    $score->($plr, 'maxscore', undef, undef, $when);
  }

  #--- First Ascension

  if(
    exists $s{'games'}{'data'}{'ascended'}
    && @{$s{'games'}{'data'}{'ascended'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'ascended'}[0]);
    my $plr = $g->{'name'};
    my $when = $g->{'endtime'};
    $score->($plr, 'firstasc', undef, undef, $when);
  }

  #--- Best Behaved Ascension

  if(
    exists $s{'games'}{'data'}{'asc_by_conducts'}
    && @{$s{'games'}{'data'}{'asc_by_conducts'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'asc_by_conducts'}[0]);
    my $plr = $g->{'name'};
    my $when = $g->{'endtime'};
    $score->($plr, 'bestconduct', undef, undef, $when);
  }

  #--- Most Unique Deaths

  if(
    exists $s{'trophies'}{'unique'}
    && @{$s{'trophies'}{'unique'}}
  ) {
    my $plr = $s{'trophies'}{'unique'}[0];
    my $when = $s{'players'}{'data'}{$plr}{'unique'}{'when'};
    $score->($plr, 'unique', undef, undef, $when);
  }

  #--- Recognition Trophies

  my @trophies = @{$cfg->{'trophies'}{'ord'}{'recognition'}};

  for my $plr (@players) {
    for my $trophy (@trophies) {
      # without bells on
      if(
        grep { $_ eq $plr } @{$s{'trophies'}{'recognition'}{$trophy}}
      ) {
        my $when = $s{'players'}{'data'}{$plr}{'recognition'}{$trophy};
        $score->($plr, $trophy, undef, undef, $when);
      }
      # with bells on
      if(
        exists $s{'trophies'}{'recognition'}{$trophy . '_wbo'}
        && grep { $_ eq $plr } @{$s{'trophies'}{'recognition'}{$trophy . '_wbo'}}
      ) {
        my $when = $s{'players'}{'data'}{$plr}{'recognition'}{$trophy . '_wbo'};
        $score->($plr, $trophy . '_wbo', undef, undef, $when);
      }
    }
  }

  #--- Minor Trophies (per-role maxscores)

  my $roles = $cfg->{'roles'};

  for my $role (@$roles) {
    if(@{$s{'games'}{'data'}{'top_by_role'}{$role}}) {
      my $g = get_xrows($s{'games'}{'data'}{'top_by_role'}{$role}[0]);
      my $plr = $g->{'name'};
      my $when = $g->{'endtime'};
      $score->($plr, 'minor', { 'role' => $role }, undef, $when);
    }
  }

  #--- Who Wants To Be A Killionaire?

  if(
    exists $s{'games'}{'data'}{'games_by_kills'}
    && @{$s{'games'}{'data'}{'games_by_kills'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'games_by_kills'}[0]);
    my $plr = $g->{'name'};
    my $when = $g->{'endtime'};
    $score->($plr, 'killionaire', undef, undef, $when);
  }

  #--- Basic Extinct

  if(
    exists $s{'games'}{'data'}{'games_by_exts'}
    && @{$s{'games'}{'data'}{'games_by_exts'}}
  ) {
    my $g = get_xrows($s{'games'}{'data'}{'games_by_exts'}[0]);
    my $plr = $g->{'name'};
    my $when = $g->{'endtime'};
    $score->($plr, 'extinct', undef, undef, $when);
  }

  #--- Challenge Trophies (only the first player gets full score,
  #--- the rest gets only half)

  for my $chal (keys %{$s{'trophies'}{'challenges'}}) {
    if(@{$s{'trophies'}{'challenges'}{$chal}}) {
      my $adj = 1;
      for my $plr (@{$s{'trophies'}{'challenges'}{$chal}}) {
        my $when = $s{'players'}{'data'}{$plr}{'challenges'}{$chal}{'when'};
        $score->($plr, 'challenge', { challenge => $chal }, $adj, $when);
        $adj = 0.5;
      }
    }
  }

  #--- sort the scoring list by points, get per-player totals

  for my $plr (keys %{$s{'players'}{'data'}}) {

    # initialize scoring total
    $s{'players'}{'data'}{$plr}{'clanpts'} = 0;

    # initialize scoring time reference
    $s{'players'}{'data'}{$plr}{'clantimeref'} = undef;

    # exclude players with no scoring entries
    next if !exists $s{'players'}{'data'}{$plr}{'scoring'};

    # generate totals + time reference
    for my $scentry (@{$s{'players'}{'data'}{$plr}{'scoring'}}) {
      my $pl = $s{'players'}{'data'}{$plr};
      $pl->{'clanpts'} += $scentry->[1];
      $pl->{'clantimeref'} = $scentry->[3]
        if !defined $pl->{'clantimeref'}
           || $pl->{'clantimeref'} < $scentry->[3];
    }

    # do the sorting
    next if scalar(@{$s{'players'}{'data'}{$plr}{'scoring'}}) < 2;
    $s{'players'}{'data'}{$plr}{'scoring'} = [
      sort { $b->[1] <=> $a->[1] } @{$s{'players'}{'data'}{$plr}{'scoring'}}
    ];
  }
});

#============================================================================
# Compile the Best In Show summary scores.
#============================================================================

push(@glb_consumers, sub
{
  no integer;

  #--- iterate over clans

  for my $clan (keys %{$s{'clans'}}) {

  #--- following values are what we are compiling as the clan scoring
  #--- information

    my $score = 0;  # summary clan score
    my @breakdown;  # breakdown by player: ( player, score )
    my $timeref;    # when was the score achieved

  #--- iterate over clan members and save breakdown, sum clan points and
  #--- record the score time reference

    for my $plr (@{$s{'clans'}{$clan}{'members'}}) {
      if(exists $s{'players'}{'data'}{$plr}{'scoring'}) {
        for my $e (@{$s{'players'}{'data'}{$plr}{'scoring'}}) {
          $score += $e->[1];
          push(@breakdown, [ $plr, @$e ]);
        }
        if(($timeref // 0) < $s{'players'}{'data'}{$plr}{'clantimeref'}) {
          $timeref = $s{'players'}{'data'}{$plr}{'clantimeref'};
        }
      }
    }

  #--- record the collected data in clans.$CLAN.bestinshow, the scoring
  #--- breakdown is ordered by achievement time

    $s{'clans'}{$clan}{'bestinshow'} = {
      'score' => $score,
      'scoretimeref' => $timeref,
      'breakdown' => [ sort {
        if($a->[4] == $b->[4]) {
          return $b->[2] <=> $a->[2];
        }
        $a->[4] <=> $b->[4];
      } @breakdown ]
    };
  }

  #--- sort the Best In Show ladder (by score, ties broken by lower timeref,
  #--- ie. who got there first)

  $s{'trophies'}{'bestinshow'} = [ sort {

    if(
      $s{'clans'}{$b}{'bestinshow'}{'score'} == 0
      && $s{'clans'}{$a}{'bestinshow'}{'score'} == 0
    ) {
      return $a cmp $b;
    }

    if(
      $s{'clans'}{$b}{'bestinshow'}{'score'}
      ==
      $s{'clans'}{$a}{'bestinshow'}{'score'}
    ) {
      return
        ($s{'clans'}{$a}{'bestinshow'}{'scoretimeref'} // 0)
        <=>
        ($s{'clans'}{$b}{'bestinshow'}{'scoretimeref'} // 0);
    }

    $s{'clans'}{$b}{'bestinshow'}{'score'}
    <=>
    $s{'clans'}{$a}{'bestinshow'}{'score'}

  } keys %{$s{'clans'}} ];

  #--- record clan's rank (ie. position on the ladder)

  my $rank = 1;
  for my $clan (@{$s{'trophies'}{'bestinshow'}}) {
    last if $s{'clans'}{$clan}{'bestinshow'}{'score'} == 0;
    $s{'clans'}{$clan}{'bestinshow'}{'rank'} = $rank++;
  }

});

#============================================================================
# Store last 10 clan games under ${clans}{}{games} in reverse chronological
# order.
#============================================================================

push(@glb_consumers, sub
{
  #--- iterate over clans

  for my $clan (keys %{$s{'clans'}}) {
    my @games;
    my @ascs;

  #--- iterate over clan members and collect their games into @games

    for my $plr (@{$s{'clans'}{$clan}{'members'}}) {
      next if !exists $s{'players'}{'data'}{$plr}{'cnt_ascensions'};
      push(@games, @{$s{'players'}{'data'}{$plr}{'games'}});
    }

  #--- save number of clan games

    $s{'clans'}{$clan}{'cnt_games'} = scalar(@games);

  #--- select and sort ascended games

    @ascs = sort {
      get_xrows($b)->{'endtime'} <=> get_xrows($a)->{'endtime'}
    } grep {
      is_ascended($_);
    } @games;

    $s{'clans'}{$clan}{'ascensions'} = \@ascs;

  #--- sort the games list by 'endtime'

    if(@games) {
      @games = sort {
        get_xrows($b)->{'endtime'} <=> get_xrows($a)->{'endtime'}
      } @games;

  #--- assign clan sequence numbers

      my $gidx = @games - 1;
      for my $game (@games) {
        get_xrows($game)->{'_cid'} = $gidx;
        $gidx--;
      }

  #--- keep only first 10 entries

      my $keep = 10;
      @games = grep { !get_xrows($_)->{'_scum'} && $keep-- > 0; } @games;

    }

    $s{'clans'}{$clan}{'games'} = \@games;
  }
});

#============================================================================
# %s.trophies.brief tree; this contains holder of all trophies in terse way
# with no extraneous information around; this is intended to support bot
# announcement
#============================================================================

push(@glb_consumers, sub
{
  #--- auxiliar function for player name retrieval by game id

  my $g = sub {
    if(!defined $_[0]) {
      return undef;
    } else {
      return get_xrows($_[0])->{'name'};
    }
  };

  #--- recognition trophies

  for my $trophy (@{$cfg->{'trophies'}{'ord'}{'recognition'}}) {
    $s{'trophies'}{'brief'}{$trophy}
    = $s{'trophies'}{'recognition'}{$trophy} // [];
    next if $cfg->{'trophies'}{'display'}{$trophy} =~ /star/i;
    $s{'trophies'}{'brief'}{"${trophy}_wbo"}
    = $s{'trophies'}{'recognition'}{"${trophy}_wbo"} // [];
  }

  #--- challenge trophies

  for my $chal (@{$cfg->{'trophies'}{'ord'}{'challenges'}}) {
    if(exists $s{'trophies'}{'challenges'}{$chal}) {
      $s{'trophies'}{'brief'}{'challenge'}{$chal}
      = $s{'trophies'}{'challenges'}{$chal};
    } else {
      $s{'trophies'}{'brief'}{'challenge'}{$chal} = [];
    }
  }

  #--- minor trophies

  for my $role (@{$cfg->{'roles'}}) {
    $s{'trophies'}{'brief'}{'minor'}{$role}
    = $g->($s{'games'}{'data'}{'top_by_role'}{$role}[0] // undef);
  }

  #--- killionaire

  $s{'trophies'}{'brief'}{'killionaire'}
  = $g->($s{'games'}{'data'}{'games_by_kills'}[0] // undef);

  #--- basic extinct

  $s{'trophies'}{'brief'}{'extinct'}
  = $g->($s{'games'}{'data'}{'games_by_exts'}[0] // undef);

  #--- highest scoring ascension

  $s{'trophies'}{'brief'}{'maxscore'}
  = $g->($s{'games'}{'data'}{'asc_by_maxscore'}[0] // undef);

  #--- unique deaths

  $s{'trophies'}{'brief'}{'unique'}
  = $s{'trophies'}{'unique'}[0] // undef;

  #--- first ascension

  $s{'trophies'}{'brief'}{'firstasc'}
  = $g->($s{'games'}{'data'}{'ascended'}[0] // undef);

  #--- best behaved ascension

  $s{'trophies'}{'brief'}{'bestconduct'}
  = $g->($s{'games'}{'data'}{'asc_by_conducts'}[0] // undef);

  #--- lowest scored ascension

  $s{'trophies'}{'brief'}{'minscore'}
  = $g->($s{'games'}{'data'}{'asc_by_minscore'}[0] // undef);

  #--- fastest ascension: realtime

  $s{'trophies'}{'brief'}{'minrealtime'}
  = $g->($s{'games'}{'data'}{'asc_by_duration'}[0] // undef);

  #--- fastest ascension: gametime

  $s{'trophies'}{'brief'}{'mingametime'}
  = $g->($s{'games'}{'data'}{'asc_by_turns'}[0] // undef);

  #--- most ascensions

  $s{'trophies'}{'brief'}{'mostascs'}
  = $s{'players'}{'meta'}{'ord_by_ascs'}[0] // undef;

  #--- best of 13

  $s{'trophies'}{'brief'}{'best13'}
  = $s{'trophies'}{'best13'}[0] // undef;

  #--- best in show

  # this following code ensure that only clans with non-zero score can
  # get reported as having got Best In Show

  $s{'trophies'}{'brief'}{'bestinshow'} = undef;
  if(
    @{$s{'trophies'}{'bestinshow'}}
    && $s{'clans'}{ $s{'trophies'}{'bestinshow'}[0] }{'bestinshow'}{'score'}
  ) {
    $s{'trophies'}{'brief'}{'bestinshow'}
    = $s{'trophies'}{'bestinshow'}[0];
  }

});

#============================================================================
# Information about servers in %s.servers
#============================================================================

push(@glb_consumers, sub
{
  #--- iterate over configured servers

  for my $server (keys %{$cfg->{'sources'}}) {
    my $r = $s{'servers'}{$server} = {};

  #--- find all games for given server

    my @games = grep {
      $_->{'_src'} eq $server;
    } @{$s{'games'}{'data'}{'all'}};

    $r->{'cnt_games'} = @games;

  #--- get count of unique players for given server

    {
      my %unique_players;
      for (@games) {
        $unique_players{ $_->{'name'} } = 0;
      }
      $r->{'cnt_players'} = keys %unique_players;
    }

  }

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
  $cmd_debug,         # --debug
  $cmd_trophies,      # --trophies[=FILE]
  $cmd_ping,          # --[no]ping
  $cmd_coalesce,      # --coalesce=FILE
);

$cmd_ping = 1;

if(!GetOptions(
  'debug' => \$cmd_debug,
  'trophies:s' => \$cmd_trophies,
  'ping!' => \$cmd_ping,
  'coalesce=s' => \$cmd_coalesce,
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
      push(@{$cfg->{'unique'}{'compiled'}{"death_${list}_list"}}, qr/^$l$/);
      push(@{$cfg->{'unique'}{'plain'}{"death_${list}_list"}}, $l);
    }
    close(F);
  }
}

#--- read the clan information

if(
  exists $cfg->{'clandb'}
  && defined $cfg->{'clandb'}
  && -f $cfg->{'clandb'}
) {
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

# Note: This code partially instantiates the players in the $s{players}{data}
# tree; this instantiation does not contain many important keys so care must
# be taken when processing players to exclude these partially instantiated
# ones; otherwise warnings about undefined data will be raised.

if($cfg->{'challenges'}{'status'}) {
  open(F, '<', $cfg->{'challenges'}{'status'})
    or die "Could not open challenge status file";
  while(my $l = <F>) {
    chomp($l);
    my @chal = split(/:/, $l);

    # enfore end limit (we are not enforcing the start bound because we expect
    # the challenges to be reset at the start of the tournament)

    next if
      exists $cfg->{'time'}{'endtime'}
      && defined $cfg->{'time'}{'endtime'}
      && $chal[0] >= $cfg->{'time'}{'endtime'};

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

    # enforce time start/end limits

    next if
      exists $cfg->{'time'}{'starttime'}
      && defined $cfg->{'time'}{'starttime'}
      && $xrow->{'starttime'} < $cfg->{'time'}{'starttime'};

    next if
      exists $cfg->{'time'}{'endtime'}
      && defined $cfg->{'time'}{'endtime'}
      && $xrow->{'endtime'} >= $cfg->{'time'}{'endtime'};

    $xrow->{'_src'} = $src;
    push(@merged_xlog, $xrow);
  }
  close($xlog);
}

#--- open coalesced xlogfile

my $coalesced;
if($cmd_coalesce && $cfg->{'xlogfile'}) {
  open($coalesced, '>', $cmd_coalesce)
    or die "Failed to open file $cmd_coalesce";
}

#--- iterate over combined xlogfile rows from all sources

for my $xrow (sort { $a->{'endtime'} <=> $b->{'endtime'} } @merged_xlog) {

#--- invoke row consumers

  for my $consumer (@row_consumers) {
    $consumer->($xrow);
  }

#--- write out coalesced xlogfile

  next if !defined($coalesced);
  print $coalesced join("\t", do {
    my @j;
    for (@{$cfg->{'xlogfile'}}) {
      push(@j, $_ . '=' . ( $xrow->{$_} // ''));
    }
    @j;
  }), "\n";
}
close($coalesced) if $coalesced;
undef @merged_xlog;

#--- invoke global consumers

for my $consumer (@glb_consumers) {
  $consumer->();
}

#--- ping scan of servers

for my $server (keys %{$cfg->{'sources'}}) {
  my $ip = $cfg->{'sources'}{$server}{'ip'} // undef;
  $s{'servers'}{$server}{'reachable'} = undef;

  next if
    !$ip
    || !$cmd_ping
    || !exists $cfg->{'ping'}
    || !defined $cfg->{'ping'};

  my $result = system(sprintf($cfg->{'ping'}, $ip)) >> 8;
  $s{'servers'}{$server}{'reachable'} = $result ? JSON::false : JSON::true;
}

#--- make configuration available to templates

delete $cfg->{'unique'}{'compiled'};
$s{'cfg'} = $cfg;

#--- timestamp

$s{'aux'}{'time'} = time();
$s{'aux'}{'timefmt'} = format_datetime($s{'aux'}{'time'});

if(
  exists $cfg->{'time'}{'starttime'}
  && exists $cfg->{'time'}{'endtime'}
) {
  if($s{'aux'}{'time'} < $cfg->{'time'}{'starttime'}) {
    $s{'aux'}{'phase'} = 'before';
  } elsif($s{'aux'}{'time'} >= $cfg->{'time'}{'endtime'}) {
    $s{'aux'}{'phase'} = 'after';
  } else {
    $s{'aux'}{'phase'} = 'during';
  }
}

#--- debug: save the compiled scoreboard data as JSON

if($cmd_debug) {
  open(JS, '>', "debug.scoreboard.$$") or die;
  print JS JSON->new->pretty(1)->encode(\%s), "\n";
  close(JS);
}

#--- save trophies file

if(defined $cmd_trophies) {
  if(!$cmd_trophies) { $cmd_trophies = 'trophies.json'; }
  open(TROPHIES, '>', $cmd_trophies) or die;
  print TROPHIES JSON->new->pretty(1)->encode($s{'trophies'}{'brief'});
  close(TROPHIES);
}

#--- template processing

process_templates(undef, \%s);
process_templates('clans', \%s, 'clan', [ keys %{$s{'clans'}} ]);
process_templates('players', \%s, 'player', [ keys %{$s{'players'}{'data'}} ]);

#--- release lock file

unlink($lockfile);
