# /dev/null/nethack Tribute 2017

Scoreboard for the Devnull Tribute 2017 tournament.

In September 2017 the /dev/null/nethack organizer Krystal
announced that he is retiring the long running tournament.  A group of
players from Team Splat decided to run "Tribute" tournament in its place
in November 2017 as a quick way to have a replacement tournament.  This
code implements scoreboard that is supposed to imitiate the structure of
the original tournament.

---

## CONFIGURATION

The statistics generation script is configured using JSON file `dnt.conf`
that is expected to be in the current directory.  Following keys are
required:

`sources`

Paths to tournament xlogfiles an challenge status files, defined as hash
where keys are (preferably) three-letter server codes. This points to hash
with keys "xlogfile" and "challenges" that contain actual pathnames.
It is assumed that remote xlogfiles/challenge files are synced by means of
wget or similar.  Xlogfiles can use both `:` or `HTAB` as field separator.

`clandb`

Path to clans database in SQLite format.


## HOW IT WORKS

The script reads the xlogfile and other supporting data sources into memory
and compiles in-memory scoreboard structure that is then passed into HTML
templates that are used to generate actual static website. The in-memory
scoreboard is held as a tree with its top level held in the `%s` hash. The
in-memory data structure is documented below.

### GAMES

%s{**games**}{**data**}{**all**}
List of all games in the order they appear in the xlogfile. This list
is created so that the individual games can be referenced from other
parts of the scoreboard. This list contains the actual data, all other list
under `%s{games}{data}` are only lists of row ids.

%s{**games**}{**data**}{**ascended**}
List of references to ascended games in chronological order.

### PLAYERS

%s{**players**}{**data**}{*playername*}{**games**}  
Ordered list of all player's games as they appear in the xlogfile.

%s{**players**}{**data**}{*playername*}{**cnt_games**}  
%s{**players**}{**data**}{*playername*}{**cnt_ascensions**}  
Counters of total games and ascended games.

%s{**players**}{**data**}{*playername*}{**cnt_asc_turns**}  
Sum of turns in all ascending games. This may be used to break ties where
players have the same number of ascending games.

%s{**players**}{**meta**}{**ord_by_ascs**}  
List of players ordered by number of ascensions (descending), ties are
broken by ascension ratio.

### CLANS

### TROPHIES


