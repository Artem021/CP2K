!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_machine
   USE ISO_FORTRAN_ENV, ONLY: input_unit, &
                              output_unit
   USE dbcsr_kinds, ONLY: default_string_length, &
                          dp, &
                          int_8
   USE dbcsr_machine_internal, ONLY: &
      m_abort, m_chdir, m_flush_internal => m_flush, m_getarg, m_getcwd, m_getlog, m_getpid, &
      m_hostnm, m_iargc, m_memory, m_memory_details, m_memory_max, m_mov, m_procrun

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads, OMP_GET_WTIME

   IMPLICIT NONE

   ! Except for some error handling code, all code should
   ! get a unit number from the print keys or from the logger, in order
   ! to guarantee correct output behavior,
   ! for example in farming or path integral runs
   ! default_input_unit should never be used
   ! but we need to know what it is, as we should not try to open it for output
   INTEGER, PUBLIC, PARAMETER                   :: default_output_unit = output_unit, &
                                                   default_input_unit = input_unit

   PRIVATE

   PUBLIC :: m_walltime, m_datum, m_flush, m_flush_internal, &
             m_hostnm, m_getcwd, m_getlog, m_getpid, m_getarg, m_procrun, &
             m_memory, m_iargc, m_abort, m_chdir, m_mov, m_memory_details, &
             m_energy, m_memory_max, m_cpuinfo

   ! should only be set according to the state in &GLOBAL
   LOGICAL, SAVE, PUBLIC :: flush_should_flush = .FALSE.

CONTAINS

   SUBROUTINE m_flush(lunit)
      !! flushes units if the &GLOBAL flag is set accordingly
      !! @note
      !! flushing might degrade performance significantly (30% and more)

      INTEGER, INTENT(IN)                                :: lunit

      IF (flush_should_flush) CALL m_flush_internal(lunit)
   END SUBROUTINE
   FUNCTION m_walltime() RESULT(wt)
      !! returns time from a real-time clock, protected against rolling
      !! early/easily
      !! @note
      !! same implementation for all machines.
      !! might still roll, if not called multiple times per count_max/count_rate

#if defined(__LIBXSMM)
      USE libxsmm, ONLY: libxsmm_timer_tick, libxsmm_timer_duration
#endif
      REAL(KIND=dp)                                      :: wt

#if defined(__LIBXSMM)
      wt = libxsmm_timer_duration(0_int_8, libxsmm_timer_tick())
#else

      INTEGER(KIND=int_8)                                :: count
      INTEGER(KIND=int_8), SAVE                          :: count_max, count_rate, cycles = -1, &
                                                            last_count
!$    IF (.FALSE.) THEN
! count lies in [0,count_max] and increases monotonically

         IF (cycles == -1) THEN ! get parameters of system_clock and initialise
            CALL SYSTEM_CLOCK(count_rate=count_rate, count_max=count_max)
            cycles = 0
            last_count = 0
         END IF

         CALL SYSTEM_CLOCK(count=count)

         ! protect against non-standard cases where time might be non-monotonous,
         ! but it is unlikely that the clock cycled (e.g. underlying system clock adjustments)
         ! i.e. if count is smaller than last_count by only a small fraction of count_max,
         ! we use last_count instead
         ! if count is smaller, we assume that the clock cycled.
         IF (count < last_count) THEN
            IF (last_count - count < count_max/100) THEN
               count = last_count
            ELSE
               cycles = cycles + 1
            END IF
         END IF

         ! keep track of our history
         last_count = count

         wt = (REAL(count, KIND=dp) + REAL(cycles, KIND=dp)*(1.0_dp + REAL(count_max, KIND=dp))) &
              /REAL(count_rate, KIND=dp)
!$    ELSE
!$       wt = OMP_GET_WTIME()
!$    END IF
#endif
   END FUNCTION m_walltime

   SUBROUTINE m_cpuinfo(model_name)
      !! reads /proc/cpuinfo if it exists (i.e. Linux) to return relevant info

      CHARACTER(LEN=default_string_length)               :: model_name
         !! as obtained from the 'model name' field, UNKNOWN otherwise

      INTEGER, PARAMETER                                 :: bufferlen = 2048

      CHARACTER(LEN=bufferlen)                           :: buffer
      INTEGER                                            :: i, icol, iline, imod, stat

      model_name = "UNKNOWN"
      buffer = ""
      OPEN (121245, FILE="/proc/cpuinfo", ACTION="READ", STATUS="OLD", ACCESS="STREAM", IOSTAT=stat)
      IF (stat == 0) THEN
         DO i = 1, bufferlen
            READ (121245, END=999) buffer(I:I)
         END DO
999      CLOSE (121245)
         imod = INDEX(buffer, "model name")
         IF (imod > 0) THEN
            icol = imod - 1 + INDEX(buffer(imod:), ":")
            iline = icol - 1 + INDEX(buffer(icol:), NEW_LINE('A'))
            IF (iline == icol - 1) iline = bufferlen + 1
            model_name = buffer(icol + 1:iline - 1)
         END IF
      END IF
   END SUBROUTINE m_cpuinfo

   FUNCTION m_energy() RESULT(wt)
      !! returns the energy used since some time in the past.
      !! The precise meaning depends on the infrastructure is available.
      !! In the cray_pm_energy case, this is the energy used by the node in kJ.

      REAL(KIND=dp)                            :: wt

#if defined(__CRAY_PM_ENERGY)
      wt = read_energy("/sys/cray/pm_counters/energy")
#elif defined(__CRAY_PM_ACCEL_ENERGY)
      wt = read_energy("/sys/cray/pm_counters/accel_energy")
#else
      wt = 0.0 ! fallback default
#endif

   END FUNCTION m_energy

#if defined(__CRAY_PM_ACCEL_ENERGY) || defined(__CRAY_PM_ENERGY)
   FUNCTION read_energy(filename) RESULT(wt)
      !! reads energy values from the sys-filesystem
      CHARACTER(LEN=*)                                   :: filename
      REAL(KIND=dp)                                      :: wt

      CHARACTER(LEN=80)                                  :: DATA
      INTEGER                                            :: i, iostat
      INTEGER(KIND=int_8)                                :: raw

      OPEN (121245, FILE=filename, ACTION="READ", STATUS="OLD", ACCESS="STREAM")
      DO I = 1, 80
         READ (121245, END=999) DATA(I:I)
      END DO
999   CLOSE (121245)
      DATA(I:80) = ""
      READ (DATA, *, IOSTAT=iostat) raw
      IF (iostat .NE. 0) THEN
         wt = 0.0_dp
      ELSE
         ! convert from J to kJ
         wt = raw/1000.0_dp
      END IF
   END FUNCTION read_energy
#endif

   SUBROUTINE m_datum(cal_date)
      !! returns a datum in human readable format using a standard Fortran routine
      CHARACTER(len=*), INTENT(OUT)                      :: cal_date

      CHARACTER(len=10)                                  :: time
      CHARACTER(len=8)                                   :: date

      CALL DATE_AND_TIME(date=date, time=time)
      cal_date = date(1:4)//"-"//date(5:6)//"-"//date(7:8)//" "//time(1:2)//":"//time(3:4)//":"//time(5:10)

   END SUBROUTINE m_datum

END MODULE dbcsr_machine
