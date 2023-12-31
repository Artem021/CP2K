!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

PROGRAM dbcsr_example_3
   !! DBCSR example 3:
   !! This example shows how to multiply two dbcsr matrices

   USE mpi
   USE dbcsr_api, ONLY: &
      dbcsr_create, dbcsr_distribution_get, dbcsr_distribution_new, dbcsr_distribution_release, &
      dbcsr_distribution_type, dbcsr_finalize, dbcsr_finalize_lib, dbcsr_get_stored_coordinates, &
      dbcsr_init_lib, dbcsr_multiply, dbcsr_nblkcols_total, dbcsr_nblkrows_total, dbcsr_print, &
      dbcsr_put_block, dbcsr_release, dbcsr_type, dbcsr_type_no_symmetry, dbcsr_type_real_8

   IMPLICIT NONE

   TYPE(dbcsr_type)                         :: matrix_a, matrix_b, matrix_c

   INTEGER, DIMENSION(:), POINTER           :: col_blk_sizes, row_blk_sizes
   INTEGER                                  :: group, numnodes, mynode, ierr, &
                                               nblkrows_total, nblkcols_total, &
                                               node_holds_blk, max_nze, nze, row, col, row_s, col_s, &
                                               max_row_size, max_col_size
   INTEGER, DIMENSION(2)                    :: npdims
   INTEGER, DIMENSION(:), POINTER           :: col_dist, row_dist
   TYPE(dbcsr_distribution_type)            :: dist
   REAL(KIND=KIND(0.0D0)), DIMENSION(:), ALLOCATABLE :: values
   LOGICAL, DIMENSION(2)                    :: period = .TRUE.
!$ INTEGER                                  :: provided_tsl

   !***************************************************************************************

   !
   ! initialize mpi
!$ IF (.FALSE.) THEN
      CALL mpi_init(ierr)
      IF (ierr /= 0) STOP "Error in MPI_Init"
!$ ELSE
!$    CALL mpi_init_thread(MPI_THREAD_FUNNELED, provided_tsl, ierr)
!$    IF (ierr /= 0) STOP "Error in MPI_Init_thread"
!$    IF (provided_tsl .LT. MPI_THREAD_FUNNELED) THEN
!$       STOP "MPI library does not support the requested level of threading (MPI_THREAD_FUNNELED)."
!$    END IF
!$ END IF

   !
   ! setup the mpi environment
   CALL mpi_comm_size(MPI_COMM_WORLD, numnodes, ierr)
   IF (ierr /= 0) STOP "Error in MPI_Comm_size"
   npdims(:) = 0
   CALL mpi_dims_create(numnodes, 2, npdims, ierr)
   IF (ierr /= 0) STOP "Error in MPI_Dims_create"
   CALL mpi_cart_create(MPI_COMM_WORLD, 2, npdims, period, .FALSE., group, ierr)
   IF (ierr /= 0) STOP "Error in MPI_Cart_create"

   CALL mpi_comm_rank(MPI_COMM_WORLD, mynode, ierr)
   IF (ierr /= 0) STOP "Error in MPI_Comm_rank"
   WRITE (*, *) 'mynode ', mynode, ' numnodes', numnodes

   !***************************************************************************************
   !
   ! initialize the DBCSR library
   CALL dbcsr_init_lib(MPI_COMM_WORLD)

   !
   ! the matrix will contain nblkrows_total row blocks and nblkcols_total column blocks
   nblkrows_total = 4
   nblkcols_total = 4

   !
   ! set the block size for each row and column
   ALLOCATE (row_blk_sizes(nblkrows_total), col_blk_sizes(nblkcols_total))
   row_blk_sizes(:) = 2
   col_blk_sizes(:) = 2

   !
   ! set the row and column distributions (here the distribution is set randomly)
   CALL random_dist(row_dist, nblkrows_total, npdims(1))
   CALL random_dist(col_dist, nblkcols_total, npdims(2))

   !
   ! set the dbcsr distribution object
   CALL dbcsr_distribution_new(dist, group=group, row_dist=row_dist, col_dist=col_dist, reuse_arrays=.TRUE.)

   !
   ! create the dbcsr matrices, i.e. a double precision non symmetric matrix
   ! with nblkrows_total x nblkcols_total blocks and
   ! sizes "sum(row_blk_sizes)" x "sum(col_blk_sizes)", distributed as
   ! specified by the dist object
   CALL dbcsr_create(matrix=matrix_a, &
                     name="this is my matrix a", &
                     dist=dist, &
                     matrix_type=dbcsr_type_no_symmetry, &
                     row_blk_size=row_blk_sizes, &
                     col_blk_size=col_blk_sizes, &
                     data_type=dbcsr_type_real_8)

   CALL dbcsr_create(matrix=matrix_b, &
                     name="this is my matrix b", &
                     dist=dist, &
                     matrix_type=dbcsr_type_no_symmetry, &
                     row_blk_size=row_blk_sizes, &
                     col_blk_size=col_blk_sizes, &
                     data_type=dbcsr_type_real_8)

   CALL dbcsr_create(matrix=matrix_c, &
                     name="this is my matrix c", &
                     dist=dist, &
                     matrix_type=dbcsr_type_no_symmetry, &
                     row_blk_size=row_blk_sizes, &
                     col_blk_size=col_blk_sizes, &
                     data_type=dbcsr_type_real_8)

   ! get the maximum block size of the matrix
   max_row_size = MAXVAL(row_blk_sizes)
   max_col_size = MAXVAL(col_blk_sizes)
   max_nze = max_row_size*max_col_size

   !
   ! set up the a matrix
   CALL dbcsr_distribution_get(dist, mynode=mynode)
   ALLOCATE (values(max_nze))
   DO row = 1, dbcsr_nblkrows_total(matrix_a)
      DO col = MAX(row - 1, 1), MIN(row + 1, dbcsr_nblkcols_total(matrix_a))
         row_s = row; col_s = col
         CALL dbcsr_get_stored_coordinates(matrix_a, row_s, col_s, node_holds_blk)
         IF (node_holds_blk .EQ. mynode) THEN
            nze = row_blk_sizes(row_s)*col_blk_sizes(col_s)
            CALL RANDOM_NUMBER(values(1:nze))
            CALL dbcsr_put_block(matrix_a, row_s, col_s, values(1:nze))
         END IF
      END DO
   END DO
   DEALLOCATE (values)

   !
   ! set up the b matrix
   CALL dbcsr_distribution_get(dist, mynode=mynode)
   ALLOCATE (values(max_nze))
   DO row = 1, dbcsr_nblkrows_total(matrix_b)
      DO col = MAX(row - 1, 1), MIN(row + 1, dbcsr_nblkcols_total(matrix_b))
         row_s = row; col_s = col
         CALL dbcsr_get_stored_coordinates(matrix_b, row_s, col_s, node_holds_blk)
         IF (node_holds_blk .EQ. mynode) THEN
            nze = row_blk_sizes(row_s)*col_blk_sizes(col_s)
            CALL RANDOM_NUMBER(values(1:nze))
            CALL dbcsr_put_block(matrix_b, row_s, col_s, values(1:nze))
         END IF
      END DO
   END DO
   DEALLOCATE (values)

   !
   ! finalize the dbcsr matrices
   CALL dbcsr_finalize(matrix_a)
   CALL dbcsr_finalize(matrix_b)
   CALL dbcsr_finalize(matrix_c)

   !
   ! multiply the matrices
   CALL dbcsr_multiply('N', 'N', 1.0D0, matrix_a, matrix_b, 0.0D0, matrix_c)

   !
   ! print the matrices
   CALL dbcsr_print(matrix_a)
   CALL dbcsr_print(matrix_b)
   CALL dbcsr_print(matrix_c)

   !
   ! release the matrices
   CALL dbcsr_release(matrix_a)
   CALL dbcsr_release(matrix_b)
   CALL dbcsr_release(matrix_c)

   CALL dbcsr_distribution_release(dist)
   DEALLOCATE (row_blk_sizes, col_blk_sizes)

   ! free comm
   CALL mpi_comm_free(group, ierr)
   IF (ierr /= 0) STOP "Error in MPI_Comm_free"

   ! finalize the DBCSR library
   CALL dbcsr_finalize_lib()

   !
   ! finalize mpi
   CALL mpi_finalize(ierr)
   IF (ierr /= 0) STOP "Error in MPI_finalize"

   !***************************************************************************************

CONTAINS

   SUBROUTINE random_dist(dist_array, dist_size, nbins)
      INTEGER, DIMENSION(:), INTENT(out), POINTER        :: dist_array
      INTEGER, INTENT(in)                                :: dist_size, nbins

      INTEGER                                            :: i

      ALLOCATE (dist_array(dist_size))
      DO i = 1, dist_size
         dist_array(i) = MODULO(nbins - i, nbins)
      END DO

   END SUBROUTINE random_dist

END PROGRAM dbcsr_example_3
