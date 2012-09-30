# Updates the "best ships" files
proc update-best-ships {} {
  global mcxn

  foreach {clazz cat count} \
      [::mysql::sel $mcxn "SELECT class, category, COUNT(*)
                           FROM ships
                           WHERE isPublic
                           AND name IS NOT NULL
                           AND acceleration > 5.0e-9
                           AND rotation > 1.0e-8
                           GROUP BY class, category" -flatlist] \
  {
    # Use at most 5 ships or 1/5th of the ships available, whichever is smaller
    set count [expr {min(5, int(ceil($count/5.0)))}]
    set ix 0
    foreach fileid [::mysql::sel $mcxn "SELECT fileid
                                        FROM ships
                                        WHERE isPublic
                                        AND name IS NOT NULL
                                        AND acceleration > 1.0e-9
                                        AND rotation > 1.0e-9
                                        AND class = '$clazz'
                                        AND category = $cat
                                        ORDER BY -aiscore
                                        LIMIT $count" -flatlist] \
    {
      ::abnet::writeServer admin-atomic-copy "bestship$clazz$cat$ix" $fileid
      incr ix
    }
  }
}
