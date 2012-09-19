proc update-batch-jobs {} {
  global mcxn

  # Get a list of all current jobs
  set jobs [::mysql::sel $mcxn \
                "SELECT id, job, failed, startedAt
                 FROM jobs" -flatlist]

  # Reset jobs which failed or which were started more than (about) a day ago
  # Also build a set to allow quickly finding whether a job exists.
  set now [clock seconds]
  set then [expr {$now - 24*3600}]
  set jobsExisting {}
  foreach {id job failed startedAt} $jobs {
    if {$failed || ($startedAt ne {} && $startedAt < $then)} {
      # Make ready for new run
      ::mysql::exec $mcxn "UPDATE jobs SET startedAt = NULL, failed = failed+1
                           WHERE id = $id"
    }

    dict set jobsExisting $job {}
  }

  # Create rendering jobs for public ships which do not have up-to-date
  # renderings.
  set shipFilesToRender [::mysql::sel $mcxn \
                             "SELECT fileid FROM ships
                              WHERE isPublic AND NOT rendered" -flatlist]
  foreach {fileid} $shipFilesToRender {
    set job "render-ship $fileid"
    if {![dict exists $jobsExisting $job]} {
      dict set jobsExisting $job {}
      ::mysql::exec $mcxn \
          "INSERT INTO jobs (job) values ('$job')"
    }
  }

  # Clear ship-match jobs which are not in-progress
  ::mysql::exec $mcxn "DELETE FROM jobs
                       WHERE job LIKE 'ship-match %' AND startedAt IS NULL"

  # Get new ship pairings
  ::mysql::sel $mcxn {
    INSERT INTO jobs (job)
    SELECT CONCAT('ship-match ',
                  test.fileid,
                  ' 1 ',
                  against.fileid,
                  ' 1')
    FROM ships AS test
    JOIN shipCategoryRelations
    ON test.category = shipCategoryRelations.win
    JOIN bestShips AS against
    ON test.class = against.class
    AND shipCategoryRelations.lose = against.category
    WHERE test.isPublic
    ORDER BY rand()
  }


  # Delete jobs which have failed too many times
  ::mysql::exec $mcxn "DELETE FROM jobs WHERE failed > 8"
}
