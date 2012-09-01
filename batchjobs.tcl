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
      ::mysql::exec $mcxn "UPDATE jobs SET startedAt = NULL
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
}
