!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_iterator_operations
   !! DBCSR iterator operations
   USE dbcsr_array_types, ONLY: array_data, &
                                array_exists
   USE dbcsr_data_methods, ONLY: dbcsr_data_hold, &
                                 dbcsr_data_release, &
                                 dbcsr_data_set_pointer, &
                                 dbcsr_get_data
   USE dbcsr_dist_methods, ONLY: dbcsr_distribution_has_threads, &
                                 dbcsr_distribution_num_threads, &
                                 dbcsr_distribution_thread_dist
   USE dbcsr_methods, ONLY: dbcsr_distribution
   USE dbcsr_ptr_util, ONLY: pointer_rank_remap2
   USE dbcsr_string_utilities, ONLY: stringify
   USE dbcsr_toollib, ONLY: swap
   USE dbcsr_types, ONLY: dbcsr_data_obj, &
                          dbcsr_distribution_obj, &
                          dbcsr_iterator, &
                          dbcsr_scalar_type, &
                          dbcsr_type
   USE dbcsr_kinds, ONLY: real_4, &
                          real_8
#include "base/dbcsr_base_uses.f90"

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads, omp_in_parallel

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_iterator_operations'

   INTEGER, PRIVATE, POINTER, SAVE      :: common_int_pointer

   PUBLIC :: dbcsr_iterator_start, dbcsr_iterator_stop

   PUBLIC :: dbcsr_iterator_blocks_left, dbcsr_iterator_next_block

   INTERFACE dbcsr_iterator_next_block
      MODULE PROCEDURE iterator_next_block_index, &
         iterator_next_area_block
      MODULE PROCEDURE iterator_next_2d_block_d, &
         iterator_next_2d_block_s, &
         iterator_next_2d_block_c, &
         iterator_next_2d_block_z, &
         iterator_next_1d_block_d, &
         iterator_next_1d_block_s, &
         iterator_next_1d_block_c, &
         iterator_next_1d_block_z
   END INTERFACE

   LOGICAL, PARAMETER :: careful_mod = .FALSE.

   INTEGER, PARAMETER, PRIVATE :: rpslot_owner = 1
   INTEGER, PARAMETER, PRIVATE :: rpslot_addblks = 2
   INTEGER, PARAMETER, PRIVATE :: rpslot_addoffset = 3
   INTEGER, PARAMETER, PRIVATE :: rpslot_oldblks = 4
   INTEGER, PARAMETER, PRIVATE :: rpslot_oldoffset = 5
   INTEGER, PARAMETER, PRIVATE :: rpslot_totaloffset = 6
   INTEGER, PARAMETER, PRIVATE :: rpnslots = 6

   LOGICAL, PARAMETER, PRIVATE :: detailed_timing = .FALSE.

   TYPE block_parameters
      LOGICAL :: tr
      INTEGER :: logical_rows, logical_cols
      INTEGER :: offset, nze
   END TYPE block_parameters

   TYPE dgemm_join
      INTEGER :: p_a, p_b, p_c
      INTEGER :: last_k, last_n
      TYPE(dbcsr_scalar_type) :: alpha, beta
   END TYPE dgemm_join

CONTAINS

! **************************************************************************************************
! Iterator functions
! **************************************************************************************************

   SUBROUTINE dbcsr_iterator_start(iterator, matrix, shared, dynamic, &
                                   dynamic_byrows, contiguous_pointers, read_only)
      !! Sets up an iterator
      !!
      !! Contiguous pointers
      !! Contiguous pointers may incur reallocation penalties but enable quick
      !! passing of arrays to routines with unspecified interfaces (i.e., direct
      !! calls to BLACS or MPI).
      !!
      !! Threading
      !! The TYPE(dbcsr_iterator) variable should be thread-private.
      !!
      !! The iterator has several modes of operation when used with
      !! OpenMP. Two options can be set to influence the behavior.
      !!
      !! Threading: shared vs. non-shared
      !! The "shared" flag specifies that several threads will be
      !! iterating through the same matrix.
      !! - Sharing is the default when called from an active parallel
      !! region. In the shared mode no two threads will receive the
      !! same block; i.e., the work is split among the threads.
      !! - If each (or one) thread needs to iterator through all blocks
      !! then shared should be set to .FALSE.. (E.g., when called
      !! from an enclosing MASTER region or when each thread has its
      !! own matrix.)
      !! - It is safe to use an iterator in non-shared mode with only
      !! one thread.  No thread synchronization constructs are used
      !! in this case)
      !!
      !! Threading in shared mode
      !! When in shared mode there are three possibilities to select
      !! how the blocks are distributed to the threads.
      !! <DL>
      !! <DT>Thread distribution</DT>
      !! <DD>The default is to use the thread distribution. The thread
      !! distribution statically maps rows to threads and should be
      !! used whenever retaining a consistent mapping among
      !! subsequent iterations is important.</DD>
      !! <DT>Dynamic scheduling</DT>
      !! <DD>If the dynamic flag is .TRUE., then blocks are given to
      !! threads dynamically. By default the assignment is grouped
      !! by rows (to minimize synchronization); however, if the
      !! dynamic_byrows flag is .FALSE. then every block is
      !! assigned dynamically.</DD></DL>

      TYPE(dbcsr_iterator), INTENT(OUT)                  :: iterator
         !! the iterator
      TYPE(dbcsr_type), INTENT(IN)                       :: matrix
         !! DBCSR matrix
      LOGICAL, INTENT(IN), OPTIONAL                      :: shared, dynamic, dynamic_byrows, &
                                                            contiguous_pointers, read_only
         !! The matrix is shared between several iterators. Default is .TRUE.
         !! Threads are given blocks regardless of the thread distribution; default is .FALSE.
         !! Threads are given blocks regardless of the thread distribution, but still grouped by rows; default is .FALSE.
         !! Whether returned pointers need to be contiguous; default is FALSE.
         !! User promises not to change returned data; default is FALSE

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_iterator_start'

      INTEGER                                            :: error_handle
      TYPE(dbcsr_distribution_obj)                       :: dist

!   ---------------------------------------------------------------------------

      MARK_USED(dynamic) ! only used with OMP

      CALL timeset(routineN, error_handle)
      iterator%shared = .TRUE.
!$    iterator%shared = omp_in_parallel()
      IF (PRESENT(shared)) iterator%shared = shared
      iterator%dynamic = .TRUE.
!$    iterator%dynamic = .FALSE.
!$    IF (PRESENT(dynamic)) iterator%dynamic = dynamic
      IF (PRESENT(dynamic_byrows)) THEN
         iterator%dynamic_byrows = dynamic_byrows
         IF (iterator%dynamic_byrows) iterator%dynamic = .TRUE.
      ELSE
         iterator%dynamic_byrows = iterator%dynamic
!$       iterator%dynamic_byrows = iterator%dynamic
      END IF
!$    IF (.NOT. iterator%shared) THEN
!$       iterator%dynamic = .FALSE.
!$    END IF
      dist = dbcsr_distribution(matrix)
!$    IF (.NOT. dbcsr_distribution_has_threads(dist)) &
!$       DBCSR_WARN("Thread distribution should be defined for OpenMP.")
      IF (.NOT. iterator%dynamic .AND. .NOT. dbcsr_distribution_has_threads(dist)) &
         DBCSR_ABORT("Thread distribution must be defined for non-dynamic iterator.")
!$    IF (omp_in_parallel() .AND. omp_get_num_threads() /= dbcsr_distribution_num_threads(dist)) &
!$       CALL dbcsr_abort(__LOCATION__, &
!$                        "Number of threads has changed from "// &
!$                        stringify(dbcsr_distribution_num_threads(dist))// &
!$                        " to "//stringify(omp_get_num_threads())//"!")
      !Synchronize the positions
      NULLIFY (iterator%common_pos)
      IF (iterator%dynamic) THEN
         ! All threads point into the master thread's data space
         ! (temporarily using the common_int_pointer variable). This is
         ! not the nicest OpenMP way of doing this but it is also not
         ! explicitly forbidden.
         !
!$OMP        BARRIER
!$OMP        MASTER
         ALLOCATE (iterator%common_pos)
         common_int_pointer => iterator%common_pos
         common_int_pointer = 0
!$OMP        FLUSH (common_int_pointer)
!$OMP        END MASTER
!$OMP        BARRIER
         IF (.NOT. ASSOCIATED(iterator%common_pos)) THEN
            iterator%common_pos => common_int_pointer
         END IF
!$OMP        BARRIER
      END IF
      !
      IF (PRESENT(contiguous_pointers)) THEN
         iterator%contiguous_pointers = contiguous_pointers
      ELSE
         iterator%contiguous_pointers = .TRUE.
      END IF
      IF (PRESENT(read_only)) THEN
         iterator%read_only = read_only
      ELSE
         iterator%read_only = .FALSE.
      END IF
      iterator%row = 0
      iterator%pos = 0
      iterator%rbs => array_data(matrix%row_blk_size)
      iterator%cbs => array_data(matrix%col_blk_size)
      iterator%roff => array_data(matrix%row_blk_offset)
      iterator%coff => array_data(matrix%col_blk_offset)

      iterator%local_indexing = matrix%local_indexing
      !IF(iterator%local_indexing .AND. .NOT. iterator%dynamic) &
      !   DBCSR_ABORT("Locally-indexed matrices can only have a dynamic iterator.")
      IF (iterator%local_indexing .AND. .NOT. array_exists(matrix%local_rows)) &
         CALL dbcsr_abort(__LOCATION__, &
                          "Local rows mapping array should exist when local indexing is used.")
      IF (iterator%local_indexing .AND. .NOT. array_exists(matrix%global_rows)) &
         CALL dbcsr_abort(__LOCATION__, &
                          "Global rows mapping array should exist when local indexing is used.")
      iterator%global_rows => array_data(matrix%global_rows)
      iterator%local_rows => array_data(matrix%local_rows)

      iterator%transpose = .FALSE. !matrix%transpose
      iterator%nblks = matrix%nblks
      IF (iterator%transpose) THEN
         iterator%nblkrows_total = matrix%nblkcols_total
      ELSE
         iterator%nblkrows_total = matrix%nblkrows_total
      END IF

      iterator%row_p => matrix%row_p
      iterator%col_i => matrix%col_i
      iterator%blk_p => matrix%blk_p
!$OMP     CRITICAL (crit_data)
      iterator%data_area = matrix%data_area
      CALL dbcsr_data_hold(iterator%data_area)
!$OMP     END CRITICAL (crit_data)
      iterator%row_size = 0
      IF (.NOT. iterator%dynamic) THEN
         iterator%tdist => array_data(dbcsr_distribution_thread_dist(dist))
      ELSE
         NULLIFY (iterator%tdist)
      END IF
!$    IF (iterator%dynamic) THEN
!$OMP           SINGLE
!$       IF (iterator%dynamic_byrows) THEN
!$          iterator%common_pos = omp_get_num_threads()
!$       END IF
!$OMP           END SINGLE
!$       CALL dbcsr_iterator_seek(iterator, omp_get_thread_num() + 1)
!$    ELSE
         CALL dbcsr_iterator_seek(iterator, 1)
!$    END IF
      CALL timestop(error_handle)
   END SUBROUTINE dbcsr_iterator_start

   SUBROUTINE dbcsr_iterator_stop(iterator)
      !! Stops up an iterator

      TYPE(dbcsr_iterator), INTENT(INOUT)                :: iterator
         !! the iterator

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_iterator_stop'

      INTEGER                                            :: error_handle

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, error_handle)
      iterator%row = 0
      iterator%pos = 0

      NULLIFY (iterator%tdist)
!$OMP     CRITICAL (crit_data)
      CALL dbcsr_data_release(iterator%data_area)
!$OMP     END CRITICAL (crit_data)
      IF (iterator%dynamic) THEN
!$OMP        BARRIER
!$OMP        MASTER
         common_int_pointer => iterator%common_pos
         DEALLOCATE (common_int_pointer)
!$OMP        FLUSH (common_int_pointer)
!$OMP        END MASTER
         NULLIFY (iterator%common_pos)
!$OMP        BARRIER
      END IF
      IF (iterator%local_indexing) THEN
         NULLIFY (iterator%local_rows)
         NULLIFY (iterator%global_rows)
      END IF
      CALL timestop(error_handle)
   END SUBROUTINE dbcsr_iterator_stop

   PURE SUBROUTINE find_first_valid_block(pos, maxpos, blk_p)
      !! Finds the first valid block, inclusive from the current position.
      !! If there is no valid block, pos is set to 0

      INTEGER, INTENT(INOUT)                             :: pos
         !! input: current position; output: next valid position or 0
      INTEGER, INTENT(IN)                                :: maxpos
         !! maximal allowed position
      INTEGER, DIMENSION(:), INTENT(IN)                  :: blk_p
         !! block pointers, used to check validity

!   ---------------------------------------------------------------------------
!IF (pos .LT. 1) pos = 1

      DO WHILE (pos .LE. maxpos)
         IF (blk_p(pos) .EQ. 0) THEN
            pos = pos + 1
         ELSE
            EXIT
         END IF
      END DO
      IF (pos .GT. maxpos) pos = 0
   END SUBROUTINE find_first_valid_block

   PURE SUBROUTINE find_proper_row(pos, row, maxrows, row_p)
      !! Finds the row to which the current block belongs
      !! If there is no valid block, pos is set to 0

      INTEGER, INTENT(IN)                                :: pos
         !! current position
      INTEGER, INTENT(INOUT)                             :: row
         !! input: current row; output: the row corresponding to the position
      INTEGER, INTENT(IN)                                :: maxrows
         !! maxmimum row
      INTEGER, DIMENSION(:), INTENT(IN)                  :: row_p
         !! row pointers

!   ---------------------------------------------------------------------------

      IF (pos .GT. 0) THEN
         IF (row .LT. 1) THEN
            row = 1
         ELSEIF (row .GT. maxrows) THEN
            row = maxrows
         END IF
         DO WHILE (row_p(row + 1) .LT. pos)
            row = row + 1
            IF (row .GT. maxrows) THEN
               row = 0
               EXIT
            END IF
         END DO
      ELSE
         row = 0
      END IF
   END SUBROUTINE find_proper_row

   PURE SUBROUTINE find_proper_position(pos, row, maxpos, maxrows, &
                                        blk_p, row_p, tdist, tid, local2global)
      !! Finds the next proper position accounting for threads
      !! First time: pos and row are set to 0.
      !! If there is no valid block, pos is set to 0

      INTEGER, INTENT(INOUT)                             :: pos, row
         !! current position and updated position
         !! input: current row; output: the row corresponding to the next proper position
      INTEGER, INTENT(IN)                                :: maxpos, maxrows
         !! maximum allowable position
         !! maxmimum row
      INTEGER, DIMENSION(:), INTENT(IN)                  :: blk_p, row_p
         !! block pointercs
         !! row pointers
      INTEGER, DIMENSION(1:maxrows), INTENT(IN), &
         OPTIONAL                                        :: tdist
         !! thread distribution
      INTEGER, INTENT(IN), OPTIONAL                      :: tid
         !! my thread number
      INTEGER, DIMENSION(1:*), INTENT(IN), OPTIONAL      :: local2global

      LOGICAL                                            :: local, row_inrange, row_ok

!   ---------------------------------------------------------------------------

      MARK_USED(tdist) ! only used with OMP
      MARK_USED(tid) ! only used with OMP

      local = PRESENT(local2global)
      IF (maxpos .GE. 1) THEN
         !IF (pos.EQ.0) pos = 1
         CALL find_first_valid_block(pos, maxpos, blk_p)
         CALL find_proper_row(pos, row, maxrows, row_p)
         row_inrange = row .NE. 0 .AND. row .LE. maxrows
         row_ok = row_inrange
!$       IF (present(tdist) .AND. PRESENT(tid) .AND. row_inrange) THEN
!$          IF (.NOT. local) THEN
!$             row_ok = tdist(row) .EQ. tid
!$          ELSE
!$             row_ok = tdist(local2global(row)) .EQ. tid
!$          END IF
!$       END IF
         DO WHILE (row_inrange .AND. .NOT. row_ok)
            row = row + 1
            pos = row_p(row) + 1
            IF (row .GT. maxrows) THEN
               row = 0
               EXIT
            END IF
            CALL find_first_valid_block(pos, maxpos, blk_p)
            CALL find_proper_row(pos, row, maxrows, row_p)
            row_inrange = row .NE. 0
            row_ok = row_inrange
!$          IF (present(tdist) .AND. PRESENT(tid) .AND. row_inrange) THEN
!$             IF (.NOT. local) THEN
!$                row_ok = tdist(row) .EQ. tid
!$             ELSE
!$                row_ok = tdist(local2global(row)) .EQ. tid
!$             END IF
!$          END IF
         END DO
         IF (row .EQ. 0) pos = 0
      ELSE
         pos = 0
         row = 0
      END IF
   END SUBROUTINE find_proper_position

   SUBROUTINE iterator_advance(iterator)
      !! Advances to the next block

      TYPE(dbcsr_iterator), INTENT(INOUT)                :: iterator
         !! the iterator

      INTEGER                                            :: ithread, my_old_row, p
      LOGICAL                                            :: advance, jumped_row

!   ---------------------------------------------------------------------------

      ithread = 0
!$    ithread = omp_get_thread_num()
      IF (iterator%dynamic .AND. iterator%shared) THEN
         IF (iterator%dynamic_byrows) THEN
            ! In this case common_row holds the last assigned row.
            !
            ! The idea is to advance in this thread's row. If it gets bumped
            ! into the next row, then we have to find the correct one.
            advance = .TRUE.
            DO WHILE (advance)
               iterator%pos = iterator%pos + 1
               my_old_row = iterator%row
               CALL find_proper_position_caller(iterator)
               jumped_row = iterator%row .GT. my_old_row
               advance = jumped_row
               IF (jumped_row) THEN
!$OMP                 CRITICAL (crit_common_pos)
                  ! Set the common_pos to the next available row.
                  iterator%common_pos = MAX(iterator%row, iterator%common_pos + 1)
                  iterator%row = iterator%common_pos
!$OMP                 END CRITICAL (crit_common_pos)
                  IF (iterator%row .GT. iterator%nblkrows_total) THEN
                     iterator%pos = 0
                     iterator%row = 0
                     advance = .FALSE.
                  ELSE
                     ! To be incremented in the next loop.
                     IF (.NOT. iterator%local_indexing) THEN
                        iterator%pos = iterator%row_p(iterator%row)
                     ELSE
                        iterator%pos = iterator%row_p(iterator%global_rows(iterator%row))
                     END IF
                  END IF
               END IF
            END DO
         ELSE
            ! In this case common_pos holds the last-assigned block.
            !
!$OMP           CRITICAL (crit_common_pos)
            iterator%common_pos = iterator%common_pos + 1
            iterator%pos = iterator%common_pos
            CALL find_proper_position_caller(iterator)
            p = iterator%pos
            iterator%common_pos = MAX(iterator%common_pos, p)
!$OMP           END CRITICAL (crit_common_pos)
         END IF
      ELSEIF (iterator%shared) THEN
         iterator%pos = iterator%pos + 1
         ithread = 0
!$       ithread = OMP_GET_THREAD_NUM()
         CALL find_proper_position_caller(iterator, use_ithread=ithread)
      ELSE
         iterator%pos = iterator%pos + 1
         CALL find_proper_position_caller(iterator)
      END IF
   END SUBROUTINE iterator_advance

   SUBROUTINE find_proper_position_caller(iterator, use_ithread)
      TYPE(dbcsr_iterator), INTENT(INOUT)                :: iterator
      INTEGER, INTENT(in), OPTIONAL                      :: use_ithread

      INTEGER                                            :: post_pos, post_row, pre_pos, pre_row, r

      pre_row = iterator%row
      pre_pos = iterator%pos
      IF (.NOT. iterator%local_indexing) THEN
         IF (PRESENT(use_ithread)) THEN
            CALL find_proper_position(iterator%pos, &
                                      iterator%row, iterator%nblks, iterator%nblkrows_total, &
                                      iterator%blk_p, iterator%row_p, &
                                      tdist=iterator%tdist, tid=use_ithread)
         ELSE
            CALL find_proper_position(iterator%pos, &
                                      iterator%row, iterator%nblks, iterator%nblkrows_total, &
                                      iterator%blk_p, iterator%row_p)
         END IF
      ELSE
         IF (iterator%row .GT. 0) THEN
            r = iterator%global_rows(iterator%row)
         ELSE
            r = 0
         END IF
         IF (PRESENT(use_ithread)) THEN
            CALL find_proper_position(iterator%pos, &
                                      r, iterator%nblks, SIZE(iterator%local_rows), &
                                      iterator%blk_p, iterator%row_p, &
                                      local2global=iterator%local_rows, &
                                      tdist=iterator%tdist, tid=use_ithread)
         ELSE
            CALL find_proper_position(iterator%pos, &
                                      r, iterator%nblks, SIZE(iterator%local_rows), &
                                      iterator%blk_p, iterator%row_p, &
                                      local2global=iterator%local_rows)
         END IF
         IF (r .GT. 0) THEN
            iterator%row = iterator%local_rows(r)
         ELSE
            iterator%row = 0
         END IF
      END IF
      post_row = iterator%row
      post_pos = iterator%pos
   END SUBROUTINE find_proper_position_caller

   PURE SUBROUTINE update_row_info(iterator)
      !! Updates the row info stored in the iterator
      !! @note Added to handle the complexity introduced with the transpose

      TYPE(dbcsr_iterator), INTENT(INOUT)                :: iterator
         !! the iterator

      IF (iterator%row .GT. 0) THEN
         IF (iterator%transpose) THEN
            iterator%row_size = iterator%cbs(iterator%row)
            iterator%row_offset = iterator%coff(iterator%row)
         ELSE
            iterator%row_size = iterator%rbs(iterator%row)
            iterator%row_offset = iterator%roff(iterator%row)
         END IF
      END IF
   END SUBROUTINE update_row_info

   SUBROUTINE dbcsr_iterator_seek(iterator, row)
      !! Places the iterator to the desired row.

      TYPE(dbcsr_iterator), INTENT(INOUT)                :: iterator
         !! the iterator
      INTEGER, INTENT(in)                                :: row
         !! seek to this row

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_iterator_seek'

      INTEGER                                            :: error_handle

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, error_handle)
      IF (iterator%nblks .GT. 0 .AND. row .LE. iterator%nblkrows_total) THEN
         iterator%row = row
         ! This line is replaced because iterator_advance increments the block
         ! number
         !iterator%pos = iterator%row_p(row)+1
         iterator%pos = iterator%row_p(row) ! +1-1
         CALL iterator_advance(iterator)
         CALL update_row_info(iterator)
      ELSE
         iterator%row = 0
         iterator%pos = 0
      END IF
      CALL timestop(error_handle)
   END SUBROUTINE dbcsr_iterator_seek

   SUBROUTINE iterator_next_block_index(iterator, row, column, blk, &
                                        transposed, blk_p, row_size, col_size, row_offset, col_offset)
      !! Gets the index information of the next block, no data.

      TYPE(dbcsr_iterator), INTENT(INOUT)                :: iterator
         !! the iterator
      INTEGER, INTENT(OUT)                               :: row, column, blk
         !! row of the data block
         !! column of the data block
         !! block number
      LOGICAL, INTENT(OUT), OPTIONAL                     :: transposed
         !! whether block is transposed
      INTEGER, INTENT(OUT), OPTIONAL                     :: blk_p, row_size, col_size, row_offset, &
                                                            col_offset
         !! index into block data array
         !! logical row size of block
         !! logical column size of block
         !! logical row offset of block
         !! logical column offset of block

      CHARACTER(len=*), PARAMETER :: routineN = 'iterator_next_block_index'

      INTEGER                                            :: bp, error_handle

!   ---------------------------------------------------------------------------

      IF (careful_mod) CALL timeset(routineN, error_handle)
      IF (iterator%pos .LE. iterator%nblks &
          .AND. iterator%pos .NE. 0) THEN
         row = iterator%row
         column = iterator%col_i(iterator%pos)
         IF (iterator%transpose) CALL swap(row, column)
         blk = iterator%pos
         IF (PRESENT(row_size)) row_size = iterator%row_size
         IF (PRESENT(col_size)) col_size = iterator%cbs(column)
         IF (PRESENT(row_offset)) row_offset = iterator%row_offset
         IF (PRESENT(col_offset)) col_offset = iterator%coff(column)
         IF (PRESENT(blk_p) .OR. PRESENT(transposed)) THEN
            bp = iterator%blk_p(iterator%pos)
            IF (PRESENT(blk_p)) blk_p = bp
            IF (PRESENT(transposed)) transposed = bp .LT. 0
         END IF
         CALL iterator_advance(iterator)
         CALL update_row_info(iterator)
      ELSE
         row = 0
         column = 0
      END IF
      IF (careful_mod) CALL timestop(error_handle)
   END SUBROUTINE iterator_next_block_index

   SUBROUTINE iterator_next_area_block(iterator, row, column, block, &
                                       transposed, block_number, row_size, col_size, row_offset, col_offset)
      !! Gets the next data block encapsulated in an object.

      TYPE(dbcsr_iterator), INTENT(INOUT)                :: iterator
         !! the iterator
      INTEGER, INTENT(OUT)                               :: row, column
         !! row of the data block
         !! column of the data block
      TYPE(dbcsr_data_obj), INTENT(INOUT)                :: block
         !! encapsulated data
      LOGICAL, INTENT(OUT)                               :: transposed
         !! whether the block data is transposed
      INTEGER, INTENT(OUT), OPTIONAL                     :: block_number, row_size, col_size, &
                                                            row_offset, col_offset
         !! block number
         !! logical row size of block
         !! logical column size of block
         !! logical row offset of block
         !! logical column offset of block

      CHARACTER(len=*), PARAMETER :: routineN = 'iterator_next_area_block'

      INTEGER                                            :: blk_p, block_col_size, block_row_size, &
                                                            bp, csize, error_handle, nze, rsize

!   ---------------------------------------------------------------------------

      IF (careful_mod) CALL timeset(routineN, error_handle)

      IF (iterator%pos .LE. iterator%nblks &
          .AND. iterator%pos .NE. 0) THEN
         row = iterator%row
         column = iterator%col_i(iterator%pos)
         IF (iterator%transpose) CALL swap(row, column)
         blk_p = iterator%blk_p(iterator%pos)
         transposed = blk_p .LT. 0
         bp = ABS(blk_p)
         rsize = iterator%row_size
         csize = iterator%cbs(column)
         block_row_size = rsize
         block_col_size = csize
         nze = rsize*csize
         IF (PRESENT(row_size)) row_size = rsize
         IF (PRESENT(col_size)) col_size = csize
         IF (PRESENT(row_offset)) row_offset = iterator%row_offset
         IF (PRESENT(col_offset)) col_offset = iterator%coff(column)
         ! Redirect the encapsulated pointer to the correct pointer here.
         IF (transposed) CALL swap(rsize, csize)
         CALL dbcsr_data_set_pointer(block, rsize, csize, iterator%data_area, &
                                     source_lb=bp)
         IF (PRESENT(block_number)) block_number = iterator%pos
         ! Move to the next non-deleted position.
         CALL iterator_advance(iterator)
         CALL update_row_info(iterator)
      ELSE
         row = 0
         column = 0
         IF (PRESENT(block_number)) block_number = 0
      END IF

      IF (careful_mod) CALL timestop(error_handle)

   END SUBROUTINE iterator_next_area_block

   PURE FUNCTION dbcsr_iterator_blocks_left(iterator) RESULT(blocks_left)
      !! Returns whether there any blocks left in the iterator.

      TYPE(dbcsr_iterator), INTENT(IN)                   :: iterator
         !! the iterator
      LOGICAL                                            :: blocks_left

      blocks_left = iterator%pos .NE. 0
   END FUNCTION dbcsr_iterator_blocks_left

   #:include '../data/dbcsr.fypp'
   #:for n, nametype1, base1, prec1, kind1, type1, dkind1 in inst_params_float
      SUBROUTINE iterator_next_1d_block_${nametype1}$ (iterator, row, column, block, &
                                                       transposed, block_number, row_size, col_size, row_offset, col_offset)
     !! Gets the next data block, single/double precision real/complex

         TYPE(dbcsr_iterator), INTENT(INOUT)      :: iterator
        !! the iterator
         INTEGER, INTENT(OUT)                     :: row, column
        !! row of the data block
        !! column of the data block
         ${type1}$, DIMENSION(:), POINTER :: block
        !! pointer to the data block
         LOGICAL, INTENT(OUT)                     :: transposed
        !! whether the block data is transposed
         INTEGER, INTENT(OUT), OPTIONAL           :: block_number
        !! block number
         INTEGER, INTENT(OUT), OPTIONAL           :: row_size, col_size, &
                                                     row_offset, col_offset
        !! logical row size of block
        !! logical column size of block

         INTEGER                                  :: blk_p, bp, csize, nze, rsize

!   ---------------------------------------------------------------------------
! If we're pointing to a valid block, return that block.

         IF (iterator%pos .LE. iterator%nblks &
             .AND. iterator%pos .NE. 0) THEN
            row = iterator%row
            column = iterator%col_i(iterator%pos)
            IF (iterator%transpose) CALL swap(row, column)
            blk_p = iterator%blk_p(iterator%pos)
            transposed = blk_p .LT. 0
            bp = ABS(blk_p)
            rsize = iterator%row_size
            csize = iterator%cbs(column)
            nze = rsize*csize
            IF (PRESENT(row_size)) row_size = rsize
            IF (PRESENT(col_size)) col_size = csize
            IF (PRESENT(row_offset)) row_offset = iterator%row_offset
            IF (PRESENT(col_offset)) col_offset = iterator%coff(column)
            CALL dbcsr_get_data(iterator%data_area, block, &
                                lb=bp, ub=bp + nze - 1)
            IF (PRESENT(block_number)) block_number = iterator%pos
            ! Move to the next non-deleted position.
            CALL iterator_advance(iterator)
            CALL update_row_info(iterator)
         ELSE
            row = 0
            column = 0
            NULLIFY (block)
            IF (PRESENT(block_number)) block_number = 0
         END IF
      END SUBROUTINE iterator_next_1d_block_${nametype1}$

      SUBROUTINE iterator_next_2d_block_${nametype1}$ (iterator, row, column, &
                                                       block, transposed, &
                                                       block_number, row_size, col_size, row_offset, col_offset)
     !! Gets the next data block, single/double precision real/complex

         TYPE(dbcsr_iterator), INTENT(INOUT)      :: iterator
        !! the iterator
         INTEGER, INTENT(OUT)                     :: row, column
        !! row of the data block
        !! column of the data block
         ${type1}$, DIMENSION(:, :), &
            POINTER                                :: block
        !! pointer to the data block
         LOGICAL, INTENT(OUT)                     :: transposed
        !! whether the block data is transposed
         INTEGER, INTENT(OUT), OPTIONAL           :: block_number
        !! block number
         INTEGER, INTENT(OUT), OPTIONAL           :: row_size, col_size, row_offset, col_offset
        !! logical row size of block
        !! logical column size of block

         CHARACTER(len=*), PARAMETER :: routineN = 'iterator_next_2d_block_${nametype1}$'

         INTEGER                                  :: blk_p, bp, csize, nze, rsize, &
                                                     block_row_size, block_col_size
         ${type1}$, DIMENSION(:), POINTER           :: lin_blk_p
         INTEGER                                  :: error_handle

!   ---------------------------------------------------------------------------
! If we're pointing to a valid block, return that block.

         IF (careful_mod) CALL timeset(routineN, error_handle)
         IF (iterator%pos .LE. iterator%nblks &
             .AND. iterator%pos .NE. 0) THEN
            row = iterator%row
            column = iterator%col_i(iterator%pos)
            IF (iterator%transpose) CALL swap(row, column)
            blk_p = iterator%blk_p(iterator%pos)
            transposed = blk_p .LT. 0
            bp = ABS(blk_p)
            rsize = iterator%row_size
            csize = iterator%cbs(column)
            block_row_size = rsize
            block_col_size = csize
            IF (PRESENT(row_size)) row_size = rsize
            IF (PRESENT(col_size)) col_size = csize
            IF (PRESENT(row_offset)) row_offset = iterator%row_offset
            IF (PRESENT(col_offset)) col_offset = iterator%coff(column)
            nze = rsize*csize
            IF (transposed) CALL swap(rsize, csize)
            CALL dbcsr_get_data(iterator%data_area, lin_blk_p, &
                                lb=bp, ub=bp + nze - 1)
            CALL pointer_rank_remap2(block, rsize, csize, lin_blk_p)
            IF (PRESENT(block_number)) block_number = iterator%pos
            ! Move to the next non-deleted position.
            CALL iterator_advance(iterator)
            CALL update_row_info(iterator)
         ELSE
            row = 0
            column = 0
            NULLIFY (block)
            IF (PRESENT(block_number)) block_number = 0
         END IF
         IF (careful_mod) CALL timestop(error_handle)
      END SUBROUTINE iterator_next_2d_block_${nametype1}$
   #:endfor

END MODULE dbcsr_iterator_operations
