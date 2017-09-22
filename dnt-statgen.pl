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

use Getopt::Long;
use JSON;
use Template;


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

  $s{'games'}{'data'}{'all'}[$game_id] = { (%$xrow, '_id', $game_id) };
  $game_current_id = $game_id++;
});

#============================================================================
# This stores list of references of all winning games in chronological order.
#============================================================================

push(@row_consumers, sub
{
  my $xrow = shift;

  if($xrow->{'death'} =~ /^ascended/) {
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
  }

  #--- push new game into the list

  push(@{$s{'players'}{'data'}{$plr_name}{'games'}}, $game_current_id);

  #--- increment games played counter

  $s{'players'}{'data'}{$plr_name}{'cnt_games'}++;

  #--- increment games ascended counter

  if($xrow->{'death'} =~ /^ascended/) {
    $s{'players'}{'data'}{$plr_name}{'cnt_ascensions'}++;
    $s{'players'}{'data'}{$plr_name}{'cnt_asc_turns'} += $xrow->{'turns'};
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

  my @plr_list = grep { $plr->{$_}{'cnt_ascensions'} > 0 } keys %$plr;

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

#--- read all the xlogfiles into memory

my @merged_xlog;
for my $src (keys %{$cfg->{'sources'}}) {
  open(my $xlog, '<', $cfg->{'sources'}{$src}{'xlogfile'})
    or die "Could not open the xlogfile";
  while(my $l = <$xlog>) {
    chomp($l);
    my $xrow = parse_log($l);
    $xrow->{'_src'} = $src;
    $xrow->{'_ncond'} = scalar(conduct($xrow->{'conduct'}));
    $xrow->{'_conds'} = join(' ', conduct($xrow->{'conduct'}));
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

#--- find the templates

my @templates;
my $tpath = $cfg->{'templates'}{'path'} // undef;
if($tpath && -d $tpath) {
  opendir(my $dh, $tpath)
    or die "Could not scan template directory $tpath";
  @templates = grep {
    -f "$tpath/$_" && $_ ne $cfg->{'templates'}{'player'}
  } readdir($dh);
  closedir($dh);
}

#--- process the regular templates

my $tt = Template->new(
  'OUTPUT_PATH' => $cfg->{'templates'}{'html'},
  'INCLUDE_PATH' => 'templates',
  'RELATIVE' => 1
);
for my $template (@templates) {
  my $dest_file = $template;
  $dest_file =~ s/\.tt//;
  if(!$tt->process($template, \%s, $dest_file . '.html')) {
    die $tt->error();
  }
}

#--- release lock file

unlink($lockfile);
