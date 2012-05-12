# File to implement evolution of Abendstern's genetic AI.
# This must be run by the batch job that runs within Abendstern.
# (In particular, it assumes the presence of $mcxn, a MySQL connection,
#  and Abendstern's configuration and name generation systems.)
#
# Note, however, that the toplevel of this file does NOT depend
# on these things, and can be run independently.
#
# During execution, the AI info config is mounted to genai, and
# each AI file is stored in NAME.dna and mounted to ai:NAME.

# CONFIGURATION

# Number of instances in a generation
set GENERATION_SIZE 64
# Samples per instance required to make a new generation
set SAMPLES_REQUIRED 64

# Probability of propagating an instance unmodified
set ELITIST_PROB 0.2
# Probability of mutating a single instance, after elitist
set MUTATION_PROB 0.6
# Otherwise, crossover

# Leaves are >= this index
set LEAF_INDEX 31
# Size of an expression
set EXPR_SIZE 63

#rename $ x$
#proc $ args {
#  puts "$ $args"
#  x$ {*}$args
#}

# Cortices and their outputs
set OUTPUTS {
  reflex                {edge dodge runaway}
  avoid_edge            {throttle accel brake spin}
  dodge                 {throttle accel brake spin}
  run_away              {throttle accel brake spin}
  frontal               {target}
  navigation            {throttle accel brake spin}
  target_analysis       {base power capac engine weapon shield}
  strategic_weapon      {score0 score1 score2 score3
                         score4 score5 score6 score7}
  aiming                {throttle0 accel0 brake0 spin0
                         throttle1 accel1 brake1 spin1
                         throttle2 accel2 brake2 spin2
                         throttle3 accel3 brake3 spin3
                         throttle4 accel4 brake4 spin4
                         throttle5 accel5 brake5 spin5
                         throttle6 accel6 brake6 spin6
                         throttle7 accel7 brake7 spin7}
  opportunistic_weapon  {score0 score1 score2 score3
                         score4 score5 score6 score7}
  weapon_level          {level0 level1 level2 level3
                         level4 level5 level6 level7}
}

# Parameters for any cortices that have them
set PARMS {
  frontal               {distance score_weight dislike_weight happy_weight}
}

# To determine what functions an output has access to, each even
# regex in this list is tested against "cortex:output"; if it matches,
# all functions listed are added to the list permitted
set FUNCTIONS {
  .*            {+ - * / % ^ _ | = sqrt rand max min}
  .*:spin       {acos asin atan atan2}
  (avoid_edge|dodge|run_away|navigation):.*     {cos sin tan ~}
  (strategic_weapon|aiming):.*                  {cos sin tan ~}
  (opportunistic_weapon|weapon_level):.*        {cos sin tan ~}
}

# Like FUNCTIONS, but for inputs
set INPUTS {
  reflex:.*             {sx sy svx svy sacc}
  reflex:edge           {fieldw fieldh}
  reflex:dodge          {fear painta}
  reflex:runaway        {nervous painta painpa}
  avoid_edge:.*         {sx sy st svx svy svt sacc srota sspin
                         spowerumin spowerumax spowerprod fieldw fieldh}
  dodge:.*              {sx sy st svx svy svt sacc srota sspin
                         spowerumin spowerumax spowerprod fear feart
                         painpa painpt painta paintt}
  run_away:.*           {sx sy st svx svy svt sacc srota sspin
                         spowerumin spowerumax spowerprod nervous nervoust}
  frontal:.*            {sx sy svx svy sacc ox oy ovx ovy
                         opriority ocurr otel}
  frontal:target        {orad omass}
  navigation:.*         {sx sy st svx svy svt sacc srota sspin
                         spowerumin spowerumax spowerprod ox oy ovx ovy}
  target_analysis:.*    {celldamage cxo cyo}
  target_analysis:base  {cnsidesfree cbridge}
  target_analysis:(power|engine|weapon|shield)  {sysclass}
  strategic_weapon:.*   {orad omass cx cy cvx cvy wx wy wt wn
                         spowerumin spowerumax spowerprod scapac smass}
  aiming:.*             {sx sy st svx svy svt smass srad sacc srota sspin
                         ox oy ot ovx ovy ovt omass orad
                         cx cy    cvx cvy
                         spowerumin spowerumax spowerprod}
  opportunistic_weapon:.*
                        {sx sy st svx svy svt srad smass
                         ox oy ot ovx ovy ovt orad omass
                         cx cy    cvx cvy
                         wx wy wt wn
                         spowerumin spowerumax spowerprod scapac}
  weapon_level:.*       {sx sy st svx svy svt srad smass
                         ox oy ot ovx ovy ovt orad omass
                         cx cy    cvx cvy
                         wx wy wt wn
                         spowerumin spowerumax spowerprod scapac}
}

# Returns a float with a normal distribution
# (width=4)
proc normalRand {} {
  expr {4*sqrt(-2*log(rand()))*cos(6.28318*rand())}
}

# Copies a Setting list into a Tcl list
proc s2l {s} {
  set l {}
  for {set i 0} {$i < [$ length $s]} {incr i} {
    if {"STString" == [$ getType $s.\[$i\]]} {
      lappend l [$ str $s.\[$i\]]
    } else {
      lappend l [$ float $s.\[$i\]]
    }
  }
  return $l
}

# Copies a Tcl list into a Setting list
proc l2s {s l} {
  while {[$ length $s]} {$ remix $s 0}
  foreach item $l {
    if {[string is double -strict $item]} {
      set type f
    } else {
      set type s
    }
    $ append$type $s $item
  }
}

# Returns the functions available to the given cortex/output pair
proc getFunctions {cortex output} {
  set str "$cortex:$output"
  set l {}
  foreach {ex fs} $::FUNCTIONS {
    if {[regexp $ex $str]} {
      lappend l {*}$fs
    }
  }
  return $l
}

# Returns the inputs available to the given cortex/output pair
proc getInputs {cortex output} {
  set str "$cortex:$output"
  set l {}
  foreach {ex fs} $::INPUTS {
    if {[regexp $ex $str]} {
      lappend l {*}$fs
    }
  }
  return $l
}

# Replaces an item in the given output at the given index
# with something random
proc replaceExpressionItem {lst cortex output index} {
  if {$index < $::LEAF_INDEX} {
    # Function
    set fs [getFunctions $cortex $output]
    lset lst $index [lindex $fs [expr {int(rand()*[llength $fs])}]]
  } else {
    set is [getInputs $cortex $output]
    if {rand() < 0.5} {
      # Constant
      lset lst $index [normalRand]
    } else {
      # Input
      lset lst $index [lindex $is [expr {int(rand()*[llength $is])}]]
    }
  }
  return $lst
}

# Generates a new species at the given root
proc genSpecies root {
  $ addi $root generation 0
  foreach {cortex outputs} $::OUTPUTS {
    $ add $root $cortex STList
    for {set instance 0} {$instance < $::GENERATION_SIZE} {incr instance} {
      $ append $root.$cortex STGroup
      foreach output $outputs {
        $ add $root.$cortex.\[$instance\] $output STList
        set lst [lrepeat $::EXPR_SIZE ""]
        for {set i 0} {$i < $::EXPR_SIZE} {incr i} {
          set lst [replaceExpressionItem $lst $cortex $output $i]
        }
        l2s $root.$cortex.\[$instance\].$output $lst
      }

      if {[dict exists $::PARMS $cortex]} {
        foreach parm [dict get $::PARMS $cortex] {
          $ addf $root.$cortex.\[$instance\] $parm [normalRand]
        }
      }
    }
  }
}

# Mutates one cortex instance into another
proc mutateInstance {dst src cortex} {
  foreach output [dict get $::OUTPUTS $cortex] {
    set ex [s2l $src.$output]
    set numMutations [expr {int(rand()*$::EXPR_SIZE)}]
    for {set i 0} {$i < $numMutations} {incr i} {
      set ex [replaceExpressionItem $ex $cortex $output \
              [expr {int(rand()*$::EXPR_SIZE)}]]
    }

    $ add $dst $output STList
    l2s $dst.$output $ex
  }
  if {[dict exists $::PARMS $cortex]} {
    foreach parm [dict get $::PARMS $cortex] {
      set p [$ float $src.$parm]
      if {rand()<0.9} {
        # Progressive mutation
        set p [expr {$p*(rand()*0.2+0.9)}]
      } else {
        # Random mutation
        set p [normalRand]
      }
      $ addf $dst $parm $p
    }
  }
}

# Crosses two cortices over into another
proc crossoverInstances {dst srca srcb cortex} {
  foreach output [dict get $::OUTPUTS $cortex] {
    set exa [s2l $srca.$output]
    set exb [s2l $srcb.$output]
    set exd {}
    foreach a $exa b $exb {
      lappend exd [expr {rand()<0.5? $a : $b}]
    }
    $ add $dst $output STList
    l2s $dst.$output $exd
  }
  if {[dict exists $::PARMS $cortex]} {
    foreach parm [dict get $::PARMS $cortex] {
      set pa [$ float $srca.$parm]
      set pb [$ float $srcb.$parm]
      $ addf $dst $parm [expr {rand()<0.5? $pa : $pb}]
    }
  }
}

# Performs tournament-of-four selection given a
# list of scores
proc tournamentSelect scores {
  set ixa [tournamentSelect2 $scores]
  set ixb [tournamentSelect2 $scores]
  if {[lindex $scores $ixa] > [lindex $scores $ixb]} {
    return $ixa
  } else {
    return $ixb
  }
}
proc tournamentSelect2 scores {
  set ixa [expr {int(rand()*[llength $scores])}]
  set ixb [expr {int(rand()*[llength $scores])}]
  if {[lindex $scores $ixa] > [lindex $scores $ixb]} {
    return $ixa
  } else {
    return $ixb
  }
}

# Evolves a cortex from source to destination
proc evolveCortex {dst src cortex scores} {
  # Select the greatest score first for straight
  # elitist propagation
  set bestix -1
  for {set i 0} {$i < [llength $scores]} {incr i} {
    if {$bestix == -1 || [lindex $scores $i] > $best} {
      set best [lindex $scores $i]
      set bestix $i
    }
  }
  $ append $dst STGroup
  confcpy $dst.\[0\] $src.\[$bestix\]

  while {[$ length $dst] < $::GENERATION_SIZE} {
    set dix [$ length $dst]
    $ append $dst STGroup
    if {rand() < $::ELITIST_PROB} {
      set six [tournamentSelect $scores]
      confcpy $dst.\[$dix\] $src.\[$six\]
    } elseif {rand() < $::MUTATION_PROB} {
      set six [tournamentSelect $scores]
      mutateInstance $dst.\[$dix\] $src.\[$six\] $cortex
    } else {
      set sixa [tournamentSelect $scores]
      set sixb [tournamentSelect $scores]
      crossoverInstances $dst.\[$dix\] $src.\[$sixa\] $src.\[$sixb\] $cortex
    }
  }
}

# Evolves a species from one root to the next, given
# an alternating list of cortex,scores
proc evolveSpecies {dst src scores} {
  foreach {cortex scoreset} $scores {
    $ add $dst $cortex STList
    evolveCortex $dst.$cortex $src.$cortex $cortex $scoreset
  }
}

# Examines the species at the given index in the genai root.
# If it is ready for evolution, the species is evolved.
proc examineSpecies speciesix {
  set species [$ name genai.species.\[$speciesix\]]
  log "Examine species $species"
  set generation [$ int genai.species.$species]
  set mnt ai:$species
  set scores [::mysql::sel $::mcxn "
    SELECT caiCortices.name, caiReports.instance,
           COUNT(caiReports.score), SUM(caiReports.score)
    FROM caiReports
    JOIN caiCortices
    ON caiReports.cortex = caiCortices.type
    WHERE species = $speciesix
      AND generation = $generation
      AND instance >= 0
      AND instance < $::GENERATION_SIZE
    GROUP BY caiReports.cortex,caiReports.instance" -flatlist]
  # Reformat the list into a dict(cortex,dict(instance,score)).
  # Stop if any instance has insufficient samples
  # (This won't catch instances without ANY samples, so we make
  #  a pass for that later.)
  set scoremap {}
  foreach {cortex instance numSamples score} $scores {
    if {$numSamples < $::SAMPLES_REQUIRED} {
      return
    }
    dict set scoremap $cortex $instance \
      [expr {$score/double($numSamples)}]
  }

  # Make sure all cortices and instances are accounted for
  foreach {cortex _} $::OUTPUTS {
    if {![dict exists $scoremap $cortex]} return
    for {set i 0} {$i < [$ length $mnt.$cortex]} {incr i} {
      if {![dict exists $scoremap $cortex $i]} return
    }
  }

  # Reformat dict into dict(cortex,scores[])
  set scoreset {}
  dict for {cortex instances} $scoremap {
    set scores {}
    for {set i 0} {[dict exists $instances $i]} {incr i} {
      lappend scores [dict get $instances $i]
    }
    dict set scoreset $cortex $scores
  }

  # OK, new generation
  log "Evolve $species"
  $ create $species.dna newai
  incr generation
  $ addi newai generation $generation
  evolveSpecies newai $mnt $scoreset
  $ unmodify $mnt
  $ close $mnt
  $ sync newai
  $ close newai
  $ open $species.dna $mnt
  $ seti genai.species.$species $generation
  $ sync genai

  # Clean database up
  ::mysql::exec $::mcxn \
"INSERT IGNORE INTO oldCAiReports
 (species, generation, instance, cortex, avgscore, comptime)
 SELECT species, generation, instance, cortex, avg(score), sum(comptime)
 FROM caiReports
 WHERE species=$speciesix
 AND   generation < [expr {$generation-10}]
 GROUP BY generation,instance,cortex"
  ::mysql::exec $::mcxn \
"DELETE FROM caiReports
 WHERE species=$speciesix
 AND   generation < [expr {$generation-10}]"

}

# Waits for a getfn to finish
proc wait {} {
  while {$::abnet::busy} {
    vwait ::abnet::busy
  }
}

proc geneticai_main {} {
  # Download the files
  ::abnet::getfn CAI ai_list.dat 0
  wait
  if {!$::abnet::success} {
    log "AI manifest not found, creating empty"
    $ create ai_list.dat genai
    $ add genai species STGroup
  } else {
    $ open ai_list.dat genai
  }

  for {set i 0} {$i < [$ length genai.species]} {incr i} {
    set filename "[$ name genai.species.\[$i\]].dna"
    ::abnet::getfn $filename $filename 0
    wait
    if {$::abnet::success} {
      $ open $filename "ai:[$ name genai.species.\[$i\]]"
      examineSpecies $i
    } else {
      log "Warning: Couldn't get AI: $::abnet::resultMessage"
    }
  }

  # Possibly generate new species
  if {0 == [$ length genai.species]} {
    # Generate name
    set name {}
    while {![string is ascii -strict $name]
       ||  ![string is alnum -strict $name]} {
      set name [namegenAny]
    }
    set name [string tolower $name]

    log "Creating species $name"
    $ addi genai.species $name 0
    $ create $name.dna ai:$name
    genSpecies ai:$name
    $ sync ai:$name
    $ sync genai
  }

  # Upload
  for {set i 0} {$i < [$ length genai.species]} {incr i} {
    set name [$ name genai.species.\[$i\]]
    ::abnet::putf $name.dna $name.dna 1
    wait
    if {!$::abnet::success} {
      log "Couldn't upload $name: $::abnet::resultMessage"
      return
    }
  }
  ::abnet::putf CAI ai_list.dat 1
  wait
}
