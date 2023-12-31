!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_mm_multrec
   !! Second layer of the dbcsr matrix-matrix multiplication.
   !! It divides the multiplication in a cache-oblivious manner.
   !! <b>Modification history:</b>
   !! - 2010-02-23 Moved from dbcsr_operations
   !! - 2011-11    Moved parameter-stack processing routines to
   !! dbcsr_mm_methods.
   !! - 2013-01    extensive refactoring (Ole Schuett)

   USE dbcsr_array_types, ONLY: array_data, &
                                array_equality
   USE dbcsr_block_operations, ONLY: dbcsr_data_set
   USE dbcsr_config, ONLY: dbcsr_cfg
   USE dbcsr_dist_methods, ONLY: dbcsr_distribution_col_dist, &
                                 dbcsr_distribution_has_threads, &
                                 dbcsr_distribution_local_cols, &
                                 dbcsr_distribution_local_cols_obj, &
                                 dbcsr_distribution_local_rows, &
                                 dbcsr_distribution_local_rows_obj, &
                                 dbcsr_distribution_row_dist, &
                                 dbcsr_distribution_thread_dist
   USE dbcsr_mm_csr, ONLY: &
      dbcsr_mm_csr_dev2host_init, dbcsr_mm_csr_finalize, dbcsr_mm_csr_init, &
      dbcsr_mm_csr_lib_finalize, dbcsr_mm_csr_lib_init, dbcsr_mm_csr_multiply, &
      dbcsr_mm_csr_purge_stacks, dbcsr_mm_csr_red3D, dbcsr_mm_csr_type
   USE dbcsr_types, ONLY: dbcsr_data_obj, &
                          dbcsr_type, &
                          dbcsr_work_type, &
                          dbcsr_type_complex_4, dbcsr_type_complex_8, &
                          dbcsr_type_real_4, dbcsr_type_real_8
   USE dbcsr_kinds, ONLY: int_8, &
                          real_4, &
                          real_8, &
                          sp
#include "base/dbcsr_base_uses.f90"

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_mm_multrec'
   LOGICAL, PARAMETER :: careful_mod = .FALSE.

   TYPE dbcsr_mm_multrec_type
      !! Used to carry data among the various calls.  Each thread has
      !! its own private copy.

      PRIVATE
      LOGICAL :: c_has_symmetry, keep_sparsity, keep_product_data, use_eps
         !! The product matrix has symmetry
         !! Sparsity of C matrix should be kept
         !! Use on-the-fly filtering
      INTEGER, DIMENSION(:), POINTER :: m_sizes, n_sizes, k_sizes
         !! Block sizes of A and C matrix rows, indexed locally
         !! Block sizes of B and C matrix columns, indexed locally
         !! Block sizes of A matrix columns and B matrix rows, indexed locally
      INTEGER, DIMENSION(:), POINTER :: m_global_sizes, n_global_sizes
      INTEGER, DIMENSION(:), POINTER :: c_local_rows, c_local_cols, k_locals, &
                                        c_global_rows, c_global_cols
         !! C and A matrix local rows.  Map from local row (index) to global row (value).
         !! C and B matrix local columns.  Map from local column (index) to global column (value).
         !! A matrix local columns and B matrix local rows.  Map from local row/column (index) to global row/column (value).
         !! C and A matrix global rows.  Map from global rows (index) to local rows (value).
         !! C and B matrix global columns.  Map from global columns (index) to local columns (value).

      REAL(KIND=sp), DIMENSION(:), POINTER :: row_max_epss, a_norms, b_norms
         !! Maximum eps to be used for one row.
         !! Norms of A matrix blocks.
         !! Norms of B matrix blocks.
      REAL(KIND=real_8)     :: eps
      INTEGER               :: original_lastblk
         !! Number of work matrix blocks before addition
      INTEGER(kind=int_8)   :: flop
         !! flop count
      TYPE(dbcsr_work_type), POINTER :: product_wm => Null()
      TYPE(dbcsr_mm_csr_type)        :: csr
      LOGICAL                        :: new_row_max_epss = .FALSE.
      LOGICAL                        :: initialized = .FALSE.
   END TYPE dbcsr_mm_multrec_type

   ! **************************************************************************************************
   PUBLIC :: dbcsr_mm_multrec_type
   PUBLIC :: dbcsr_mm_multrec_lib_init, dbcsr_mm_multrec_lib_finalize
   PUBLIC :: dbcsr_mm_multrec_init, dbcsr_mm_multrec_finalize
   PUBLIC :: dbcsr_mm_multrec_multiply
   PUBLIC :: dbcsr_mm_multrec_dev2host_init, dbcsr_mm_multrec_red3D
   PUBLIC :: dbcsr_mm_multrec_get_nblks, dbcsr_mm_multrec_get_nze

CONTAINS

   SUBROUTINE dbcsr_mm_multrec_lib_init()
      !! Initialize the library

      CALL dbcsr_mm_csr_lib_init()
   END SUBROUTINE

   SUBROUTINE dbcsr_mm_multrec_lib_finalize()
      !! Finalize the library
      CALL dbcsr_mm_csr_lib_finalize()
   END SUBROUTINE

   SUBROUTINE dbcsr_mm_multrec_init(this, left, right, product, &
                                    keep_sparsity, eps, row_max_epss, block_estimate, right_row_blk_size, &
                                    m_sizes, n_sizes, nlayers, keep_product_data)
      !! Sets up recursive multiplication

      TYPE(dbcsr_mm_multrec_type), INTENT(out)           :: this
      TYPE(dbcsr_type), INTENT(IN), OPTIONAL             :: left, right
         !! left DBCSR matrix
         !! right DBCSR matrix
      TYPE(dbcsr_type), INTENT(INOUT)                    :: product
         !! resulting DBCSR product matrix
      LOGICAL, INTENT(IN)                                :: keep_sparsity
         !! retain the sparsity of the existing product matrix, default is no
      LOGICAL, INTENT(IN), OPTIONAL                      :: keep_product_data
         !! Perform final reduction on C data, default is yes
      REAL(kind=real_8), INTENT(in), OPTIONAL            :: eps
         !! on-the-fly filtering epsilon
      REAL(kind=sp), DIMENSION(:), INTENT(IN), TARGET    :: row_max_epss
      INTEGER, INTENT(IN)                                :: block_estimate
      INTEGER, DIMENSION(:), INTENT(IN)                  :: right_row_blk_size
      INTEGER, DIMENSION(:), INTENT(IN), POINTER         :: m_sizes, n_sizes
      INTEGER, OPTIONAL                                  :: nlayers

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_multrec_init'
      LOGICAL, PARAMETER                                 :: dbg = .FALSE.

      INTEGER                                            :: c_nblkcols_local, c_nblkrows_local, &
                                                            handle, ithread
      INTEGER, DIMENSION(:), POINTER                     :: c_local_cols, c_local_rows

!$    INTEGER, DIMENSION(:), POINTER           :: product_thread_dist

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, handle)

      ithread = 0
!$    ithread = OMP_GET_THREAD_NUM()
      !
      IF (this%initialized) &
         DBCSR_ABORT("multrec already initialized.")

      IF (PRESENT(left) .NEQV. PRESENT(right)) &
         DBCSR_ABORT("Must both left and right provided or not.")

      IF (PRESENT(left) .AND. PRESENT(right)) THEN
         ! Ensures that the index is correctly defined.
         IF (.NOT. left%list_indexing) &
            DBCSR_ABORT("Must use list indexing for this routine.")
         IF (left%bcsc) &
            DBCSR_ABORT("Wrong routine for BCSC matrices.")

         IF (right%bcsc) &
            DBCSR_ABORT("Wrong routine for BCSC matrices.")
         IF (.NOT. right%local_indexing) &
            DBCSR_ABORT("Matrices must have local indexing.")
         IF (.NOT. left%local_indexing) &
            DBCSR_ABORT("Matrices must have local indexing.")
      END IF
      !
      ! Fill result data structure.
      this%keep_sparsity = keep_sparsity
      this%c_has_symmetry = product%symmetry
      this%keep_product_data = .TRUE.
      IF (PRESENT(keep_product_data)) THEN
         this%keep_product_data = keep_product_data
      END IF
      this%use_eps = PRESENT(eps)
      this%original_lastblk = product%wms(ithread + 1)%lastblk
      this%flop = INT(0, int_8)
      this%product_wm => product%wms(ithread + 1)

      IF (PRESENT(eps)) THEN
         this%eps = eps
      ELSE
         this%eps = 0.0_real_8
      END IF
      !
      !
!$    NULLIFY (product_thread_dist)
!$    IF (.NOT. dbcsr_distribution_has_threads(product%dist)) &
!$       DBCSR_ABORT("Missing thread distribution.")
!$    product_thread_dist => array_data( &
!$                           dbcsr_distribution_thread_dist(product%dist))
      !
      ! Find out the C/A rows and C/B columns and sizes.
      c_nblkrows_local = product%nblkrows_local
      c_local_rows => array_data(product%local_rows)
      c_nblkcols_local = product%nblkcols_local
      c_local_cols => array_data(product%local_cols)
      this%c_local_rows => c_local_rows
      this%c_local_cols => c_local_cols
      IF (dbg) WRITE (*, *) "setting up for product", product%name
      IF (careful_mod) THEN
         IF (.NOT. array_equality(dbcsr_distribution_local_rows_obj(product%dist), &
                                  product%local_rows)) THEN
            WRITE (*, *) "row dist", dbcsr_distribution_row_dist(product%dist)
            WRITE (*, *) "dist local rows", dbcsr_distribution_local_rows(product%dist)
            WRITE (*, *) " mat local rows", array_data(product%local_rows)
            DBCSR_ABORT("Array mismatch.")
         END IF
         IF (.NOT. array_equality(dbcsr_distribution_local_cols_obj(product%dist), &
                                  product%local_cols)) THEN
            WRITE (*, *) "col dist", dbcsr_distribution_col_dist(product%dist)
            WRITE (*, *) "dist local cols", dbcsr_distribution_local_cols(product%dist)
            WRITE (*, *) " mat local cols", array_data(product%local_cols)
            DBCSR_ABORT("Array mismatch.")
         END IF
         IF (SIZE(c_local_rows) /= c_nblkrows_local) &
            DBCSR_ABORT("Row count mismatch.")
         IF (SIZE(c_local_cols) /= c_nblkcols_local) &
            DBCSR_ABORT("Column count mismatch.")
      END IF
      !
      ! And the k epsilons
      IF ((PRESENT(left) .AND. PRESENT(right)) .OR. .NOT. this%use_eps) THEN
         ALLOCATE (this%row_max_epss(c_nblkrows_local))
         this%new_row_max_epss = .TRUE.
      END IF
      IF (this%use_eps) THEN
         IF (PRESENT(left) .AND. PRESENT(right)) THEN
            CALL local_filter_sp(row_max_epss, c_nblkrows_local, c_local_rows, &
                                 this%row_max_epss)
         ELSE
            this%row_max_epss => row_max_epss
         END IF
      ELSE
         this%row_max_epss(:) = -HUGE(0.0_sp)
      END IF
      !
      this%m_sizes => m_sizes
      this%n_sizes => n_sizes
      this%m_global_sizes => array_data(product%row_blk_size)
      this%n_global_sizes => array_data(product%col_blk_size)
      NULLIFY (this%k_locals)
      NULLIFY (this%k_sizes)

      !TODO: should we move this up?
      CALL dbcsr_mm_csr_init(this%csr, &
                             left=left, right=right, product=product, &
                             m_sizes=this%m_sizes, n_sizes=this%n_sizes, &
                             block_estimate=block_estimate, &
                             right_row_blk_size=right_row_blk_size, &
                             nlayers=nlayers, &
                             keep_product_data=this%keep_product_data)

      this%initialized = .TRUE.
      CALL timestop(handle)
   END SUBROUTINE dbcsr_mm_multrec_init

   SUBROUTINE dbcsr_mm_multrec_multiply(this, left, right, flop, &
                                        a_norms, b_norms, k_sizes)
      !! Multiplies two DBCSR matrices using recursive algorithm
      !! This routine sets up the multiplication.  Specifically, it <ul>
      !! <li> verifies input sanity
      !! <li> converts everything into "local indexing"
      !! </ul>

      TYPE(dbcsr_mm_multrec_type), INTENT(inout)         :: this
      TYPE(dbcsr_type), INTENT(IN)                       :: left, right
         !! left DBCSR matrix
         !! right DBCSR matrix
      INTEGER(KIND=int_8), INTENT(INOUT)                 :: flop
         !! number of effective double-precision floating point operations performed
      REAL(kind=sp), DIMENSION(:), INTENT(in), TARGET    :: a_norms, b_norms
         !! norms of left-matrix blocks
         !! norms of right-matrix blocks
      INTEGER, DIMENSION(:), INTENT(IN), POINTER         :: k_sizes

!$    INTEGER                                            :: ithread
      INTEGER                                            :: t_a_f, t_a_l, t_b_f, t_b_l
      INTEGER, DIMENSION(:), POINTER                     :: k_locals

!   ---------------------------------------------------------------------------

      IF (.NOT. this%initialized) &
         DBCSR_ABORT("multrec not initialized.")

      this%flop = 0

      ! Find out the local A columns / B rows and sizes
      ! The right%local_rows is setup by the communication engine.
      k_locals => array_data(right%local_rows)
      this%k_locals => k_locals
      this%k_sizes => k_sizes
      ! Setup the block norms
      this%a_norms => a_norms
      this%b_norms => b_norms

      ! Start local multiplication
      t_a_f = 1
      t_a_l = left%nblks
      t_b_f = 1
      t_b_l = right%nblks
!$    IF (ASSOCIATED(left%thr_c)) THEN
!$       ithread = OMP_GET_THREAD_NUM()
!$       t_a_f = left%thr_c(ithread + 1) + 1
!$       t_a_l = left%thr_c(ithread + 2)
!$    END IF
      CALL sparse_multrec(this, left, right, &
                          1, left%nblkrows_local, &
                          1, right%nblkcols_local, &
                          1, SIZE(k_locals), &
                          t_a_f, t_a_l, left%coo_l, &
                          t_b_f, t_b_l, right%coo_l, &
                          0)

      CALL dbcsr_mm_csr_purge_stacks(this%csr, left, right)

      flop = flop + this%flop
      !
   END SUBROUTINE dbcsr_mm_multrec_multiply

   SUBROUTINE dbcsr_mm_multrec_dev2host_init(this)
      !! Sets up recursive multiplication
      TYPE(dbcsr_mm_multrec_type), INTENT(inout)         :: this

!   ---------------------------------------------------------------------------

      IF (.NOT. this%initialized) &
         DBCSR_ABORT("multrec not initialized.")
      CALL dbcsr_mm_csr_dev2host_init(this%csr)
   END SUBROUTINE dbcsr_mm_multrec_dev2host_init

   SUBROUTINE dbcsr_mm_multrec_finalize(this, meta_buffer)
      !! Sets up recursive multiplication
      TYPE(dbcsr_mm_multrec_type), INTENT(inout)         :: this
      INTEGER, DIMENSION(:), INTENT(INOUT), OPTIONAL     :: meta_buffer

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_multrec_finalize'

      INTEGER                                            :: handle, ithread, lb_meta, &
                                                            nblocks, nthreads, ub_meta

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, handle)
      IF (.NOT. this%initialized) &
         DBCSR_ABORT("multrec not initialized.")

      CALL dbcsr_mm_csr_finalize(this%csr)

      ! Release the carrier
      IF (this%new_row_max_epss) DEALLOCATE (this%row_max_epss)

      IF (PRESENT(meta_buffer)) THEN
         ithread = 0; nthreads = 1
!$       ithread = OMP_GET_THREAD_NUM(); nthreads = OMP_GET_NUM_THREADS()
         ! Copy wms data into matrix
         lb_meta = meta_buffer(ithread + 1)
         nblocks = (meta_buffer(ithread + 2) - lb_meta)/3
         ub_meta = lb_meta + nblocks
         meta_buffer(lb_meta + 1:ub_meta) = this%product_wm%row_i(1:nblocks)
         lb_meta = ub_meta
         ub_meta = lb_meta + nblocks
         meta_buffer(lb_meta + 1:ub_meta) = this%product_wm%col_i(1:nblocks)
         lb_meta = ub_meta
         ub_meta = lb_meta + nblocks
         meta_buffer(lb_meta + 1:ub_meta) = this%product_wm%blk_p(1:nblocks)
      ELSE
         CALL remap_local2global(this%product_wm%row_i, &
                                 this%product_wm%col_i, &
                                 this%c_local_rows, this%c_local_cols, &
                                 this%original_lastblk + 1, this%product_wm%lastblk)

         ! if filtering is requested remove small blocks, unless the sparsity needs to be kept
         IF (this%use_eps .AND. .NOT. this%keep_sparsity) THEN
            CALL multrec_filtering(this)
         ELSE
            this%product_wm%datasize_after_filtering = this%product_wm%datasize
         END IF
      END IF

      this%initialized = .FALSE.
      CALL timestop(handle)
   END SUBROUTINE dbcsr_mm_multrec_finalize

   SUBROUTINE multrec_filtering(this)
      !! Applying in-place filtering on the workspace
      TYPE(dbcsr_mm_multrec_type), INTENT(inout)         :: this

      CHARACTER(len=*), PARAMETER :: routineN = 'multrec_filtering'

      INTEGER                                            :: handle

      CALL timeset(routineN, handle)

      SELECT CASE (this%product_wm%data_area%d%data_type)
      CASE (dbcsr_type_real_4)
         CALL multrec_filtering_s(this%eps, &
                                  this%product_wm%lastblk, &
                                  this%product_wm%row_i, &
                                  this%product_wm%col_i, &
                                  this%product_wm%blk_p, &
                                  this%m_global_sizes, this%n_global_sizes, &
                                  this%product_wm%datasize_after_filtering, &
                                  this%product_wm%data_area%d%r_sp)
      CASE (dbcsr_type_real_8)
         CALL multrec_filtering_d(this%eps, &
                                  this%product_wm%lastblk, &
                                  this%product_wm%row_i, &
                                  this%product_wm%col_i, &
                                  this%product_wm%blk_p, &
                                  this%m_global_sizes, this%n_global_sizes, &
                                  this%product_wm%datasize_after_filtering, &
                                  this%product_wm%data_area%d%r_dp)
      CASE (dbcsr_type_complex_4)
         CALL multrec_filtering_c(this%eps, &
                                  this%product_wm%lastblk, &
                                  this%product_wm%row_i, &
                                  this%product_wm%col_i, &
                                  this%product_wm%blk_p, &
                                  this%m_global_sizes, this%n_global_sizes, &
                                  this%product_wm%datasize_after_filtering, &
                                  this%product_wm%data_area%d%c_sp)
      CASE (dbcsr_type_complex_8)
         CALL multrec_filtering_z(this%eps, &
                                  this%product_wm%lastblk, &
                                  this%product_wm%row_i, &
                                  this%product_wm%col_i, &
                                  this%product_wm%blk_p, &
                                  this%m_global_sizes, this%n_global_sizes, &
                                  this%product_wm%datasize_after_filtering, &
                                  this%product_wm%data_area%d%c_dp)
      CASE DEFAULT
         DBCSR_ABORT("Invalid data type.")
      END SELECT

      CALL timestop(handle)

   END SUBROUTINE multrec_filtering

   SUBROUTINE dbcsr_mm_multrec_red3D(this, meta_buffer, data_buffer, flop, g2l_map_rows, g2l_map_cols)
      !! Make the reduction of the 3D layers in the local multrec object
      TYPE(dbcsr_mm_multrec_type), INTENT(inout)         :: this
      INTEGER, DIMENSION(:), INTENT(IN)                  :: meta_buffer
      TYPE(dbcsr_data_obj), INTENT(IN)                   :: data_buffer
      INTEGER(KIND=int_8), INTENT(INOUT)                 :: flop
      INTEGER, DIMENSION(:), INTENT(IN)                  :: g2l_map_rows, g2l_map_cols

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_multrec_red3D'

      INTEGER                                            :: handle

      CALL timeset(routineN, handle)
      IF (.NOT. this%initialized) &
         DBCSR_ABORT("multrec not initialized.")
      CALL dbcsr_mm_csr_red3D(this%csr, meta_buffer, data_buffer, flop, &
                              m_sizes=this%m_sizes, n_sizes=this%n_sizes, &
                              g2l_map_rows=g2l_map_rows, &
                              g2l_map_cols=g2l_map_cols, &
                              original_lastblk=this%original_lastblk, &
                              keep_sparsity=this%keep_sparsity)
      CALL timestop(handle)
   END SUBROUTINE dbcsr_mm_multrec_red3D

   FUNCTION dbcsr_mm_multrec_get_nblks(this) RESULT(nblks)
      !! Return number of blocks
      TYPE(dbcsr_mm_multrec_type), INTENT(IN)            :: this
      INTEGER                                            :: nblks

      nblks = this%product_wm%lastblk

   END FUNCTION dbcsr_mm_multrec_get_nblks

   FUNCTION dbcsr_mm_multrec_get_nze(this) RESULT(nze)
      !! Return data size
      TYPE(dbcsr_mm_multrec_type), INTENT(IN)            :: this
      INTEGER                                            :: nze

      nze = this%product_wm%datasize

   END FUNCTION dbcsr_mm_multrec_get_nze

   RECURSIVE SUBROUTINE sparse_multrec(this, left, right, mi, mf, ni, nf, ki, kf, &
      !! Performs recursive multiplication
                                       ai, af, a_index, bi, bf, b_index, &
                                       d)
      TYPE(dbcsr_mm_multrec_type), INTENT(INOUT)         :: this
      TYPE(dbcsr_type), INTENT(IN)                       :: left, right
      INTEGER, INTENT(IN)                                :: mi, mf, ni, nf, ki, kf, ai, af
      INTEGER, DIMENSION(3, 1:af), INTENT(IN)            :: a_index
      INTEGER, INTENT(IN)                                :: bi, bf
      INTEGER, DIMENSION(3, 1:bf), INTENT(IN)            :: b_index
      INTEGER, INTENT(IN)                                :: d

      LOGICAL, PARAMETER                                 :: dbg = .FALSE.

      INTEGER                                            :: acut, bcut, cut, K, M, N, s1

!   ---------------------------------------------------------------------------

      IF (dbg) THEN
         WRITE (*, '(I7,1X,5(A,2(1X,I7)))') d, " rm", mi, mf, ",", ni, nf, ",", ki, kf, "/", ai, af, ",", bi, bf
      END IF
      IF (.TRUE.) THEN
         IF (af .LT. ai .OR. bf .LT. bi .OR. mf .LT. mi .OR. nf .LT. ni .OR. kf .LT. ki) THEN
            IF (dbg) WRITE (*, *) "Empty"
            RETURN
         END IF
      END IF

      IF (af - ai + 1 <= dbcsr_cfg%multrec_limit%val .AND. bf - bi + 1 <= dbcsr_cfg%multrec_limit%val) THEN
         IF (af - ai + 1 .GT. 0 .AND. bf - bi + 1 .GT. 0) &
            CALL dbcsr_mm_csr_multiply(this%csr, left, right, &
                                       mi=mi, mf=mf, ni=ni, nf=nf, ki=ki, kf=kf, &
                                       ai=ai, af=af, &
                                       bi=bi, bf=bf, &
                                       m_sizes=this%m_sizes, n_sizes=this%n_sizes, k_sizes=this%k_sizes, &
                                       c_local_rows=this%c_local_rows, c_local_cols=this%c_local_cols, &
                                       c_has_symmetry=this%c_has_symmetry, keep_sparsity=this%keep_sparsity, &
                                       use_eps=this%use_eps, row_max_epss=this%row_max_epss, &
                                       flop=this%flop, &
                                       a_index=a_index, b_index=b_index, &
                                       a_norms=this%a_norms, b_norms=this%b_norms)
         RETURN
      END IF

      M = mf - mi + 1
      N = nf - ni + 1
      K = kf - ki + 1
      IF (dbg) THEN
         WRITE (*, *) 'm,k,n', M, K, N
      END IF
      IF (M >= MAX(N, K)) cut = 1
      IF (K >= MAX(N, M)) cut = 2
      IF (N >= MAX(M, K)) cut = 3
      SELECT CASE (cut)
      CASE (1)
         s1 = M/2
         acut = find_cut_row(ai, af, a_index, mi + s1 - 1)
         CALL sparse_multrec(this, left, right, mi, mi + s1 - 1, ni, nf, ki, kf, &
                             ai, acut - 1, a_index, bi, bf, b_index, d + 1)
         CALL sparse_multrec(this, left, right, mi + s1, mf, ni, nf, ki, kf, &
                             acut, af, a_index, bi, bf, b_index, d + 1)
      CASE (2)
         s1 = K/2
         acut = find_cut_col(ai, af, a_index, ki + s1 - 1)
         IF (dbg) THEN
            WRITE (*, *) N, s1, ni + s1 - 1, "/", ai, af, acut
            WRITE (*, '(3(I7))') a_index
         END IF
         bcut = find_cut_row(bi, bf, b_index, ki + s1 - 1)
         IF (dbg) THEN
            WRITE (*, *) N, s1, ni + s1 - 1, "/", bi, bf, bcut
            WRITE (*, '(3(I7))') b_index
         END IF
         CALL sparse_multrec(this, left, right, mi, mf, ni, nf, ki, ki + s1 - 1, &
                             ai, acut - 1, a_index, bi, bcut - 1, b_index, d + 1)
         CALL sparse_multrec(this, left, right, mi, mf, ni, nf, ki + s1, kf, &
                             acut, af, a_index, bcut, bf, b_index, d + 1)
      CASE (3)
         s1 = N/2
         bcut = find_cut_col(bi, bf, b_index, ni + s1 - 1)
         IF (dbg) THEN
            WRITE (*, *) N, s1, ni + s1 - 1, "/", bi, bf, bcut
            WRITE (*, '(3(I7))') b_index
         END IF
         CALL sparse_multrec(this, left, right, mi, mf, ni, ni + s1 - 1, ki, kf, &
                             ai, af, a_index, bi, bcut - 1, b_index, d + 1)
         CALL sparse_multrec(this, left, right, mi, mf, ni + s1, nf, ki, kf, &
                             ai, af, a_index, bcut, bf, b_index, d + 1)
      END SELECT
   END SUBROUTINE sparse_multrec

! ***************************************************************************************************
   PURE FUNCTION find_cut_row(ai, af, a, val) RESULT(res)
      INTEGER, INTENT(IN)                                :: ai, af
      INTEGER, DIMENSION(3, 1:af), INTENT(IN)            :: a
      INTEGER, INTENT(IN)                                :: val
      INTEGER                                            :: res

      INTEGER                                            :: i, ihigh, ilow

! do a log(N) search along the ordered index

      ilow = ai
      IF (a(1, ilow) > val) THEN
         res = ilow
         RETURN
      END IF

      ihigh = af
      IF (a(1, ihigh) <= val) THEN
         res = ihigh + 1
         RETURN
      END IF

      DO
         IF (ihigh - ilow == 1) EXIT
         i = (ilow + ihigh)/2
         IF (a(1, i) > val) THEN
            ihigh = i
         ELSE
            ilow = i
         END IF
      END DO
      res = ihigh

      ! the linear search version
      ! DO i=ai,af
      !    IF (a(i)%r>val) EXIT
      !ENDDO
      !res=i
   END FUNCTION find_cut_row

! ***************************************************************************************************
   PURE FUNCTION find_cut_col(ai, af, a, val) RESULT(res)
      INTEGER, INTENT(IN)                                :: ai, af
      INTEGER, DIMENSION(3, 1:af), INTENT(IN)            :: a
      INTEGER, INTENT(IN)                                :: val
      INTEGER                                            :: res

      INTEGER                                            :: i, ihigh, ilow

! do a log(N) search along the ordered index

      ilow = ai
      IF (a(2, ilow) > val) THEN
         res = ilow
         RETURN
      END IF

      ihigh = af
      IF (a(2, ihigh) <= val) THEN
         res = ihigh + 1
         RETURN
      END IF

      DO
         IF (ihigh - ilow == 1) EXIT
         i = (ilow + ihigh)/2
         IF (a(2, i) > val) THEN
            ihigh = i
         ELSE
            ilow = i
         END IF
      END DO
      res = ihigh

      ! the linear search version
      ! DO i=ai,af
      !    IF (a(i)%c>val) EXIT
      !ENDDO
      !res=i
   END FUNCTION find_cut_col

   PURE SUBROUTINE remap_local2global(row_i, col_i, local_rows, local_cols, &
                                      first, last)
      !! Packs a globally-indexed array into a locally-indexed array.
      INTEGER, INTENT(in)                                :: last, first
      INTEGER, DIMENSION(:), INTENT(in)                  :: local_cols, local_rows
      INTEGER, DIMENSION(1:last), INTENT(inout)          :: col_i, row_i

      INTEGER                                            :: i

      DO i = first, last
         row_i(i) = local_rows(row_i(i))
         col_i(i) = local_cols(col_i(i))
      END DO
   END SUBROUTINE remap_local2global

   PURE SUBROUTINE local_filter_sp(full_data, nle, local_elements, local_data)
      !! Gathers the local elements from all data (full_data) for
      !! single precision elements.

      REAL(KIND=sp), DIMENSION(:), INTENT(IN)            :: full_data
      INTEGER, INTENT(IN)                                :: nle
      INTEGER, DIMENSION(1:nle), INTENT(IN)              :: local_elements
      REAL(KIND=sp), DIMENSION(1:nle), INTENT(OUT)       :: local_data

      INTEGER                                            :: l

      DO l = 1, SIZE(local_data)
         local_data(l) = full_data(local_elements(l))
      END DO
   END SUBROUTINE local_filter_sp

   #:include '../data/dbcsr.fypp'
   #:for n, nametype1, base1, prec1, kind1, type1, dkind1, normname1 in inst_params_float

      SUBROUTINE multrec_filtering_${nametype1}$ (filter_eps, nblks, rowi, coli, blkp, &
                                                  rbs, cbs, nze, DATA)
     !! Applying in-place filtering on the workspace.
     !! \brief Use Frobenius norm

         REAL(kind=real_8), INTENT(IN)              :: filter_eps
         INTEGER, INTENT(INOUT)                     :: nblks, nze
         INTEGER, DIMENSION(1:nblks), INTENT(INOUT) :: rowi, coli, blkp
         INTEGER, DIMENSION(:), INTENT(IN)          :: rbs, cbs
         ${type1}$, DIMENSION(:), &
            INTENT(INOUT)                            :: DATA

         INTEGER                                    :: blk, lastblk, blk_nze, blk_p
         REAL(kind=real_8)                          :: nrm

         REAL(KIND=real_8), EXTERNAL                :: DZNRM2, DDOT
#if defined (__ACCELERATE)
         REAL(KIND=real_8), EXTERNAL                :: SCNRM2, SDOT
#else
         REAL(KIND=real_4), EXTERNAL                :: SCNRM2, SDOT
#endif

         REAL(kind=real_8)                          :: filter_eps_opt

         #:if nametype1 in ['d', 's']
            ! Avoid square root
            filter_eps_opt = filter_eps**2
         #:else
            filter_eps_opt = filter_eps
         #:endif

         lastblk = 0
         nze = 0
         !
         DO blk = 1, nblks
            blk_p = blkp(blk)
            IF (blk_p .EQ. 0) CYCLE
            blk_nze = rbs(rowi(blk))*cbs(coli(blk))
            IF (blk_nze .EQ. 0) CYCLE ! Skip empty blocks
            nrm = REAL(${normname1}$ (blk_nze, data(blk_p), 1, data(blk_p), 1)), KIND = real_8)
            IF (nrm .GE. filter_eps_opt) THEN
               ! Keep block
               lastblk = lastblk + 1
               IF (lastblk .LT. blk) THEN
                  rowi(lastblk) = rowi(blk)
                  coli(lastblk) = coli(blk)
                  blkp(lastblk) = blkp(blk)
               END IF
               nze = nze + blk_nze
            END IF
         END DO
         !
         nblks = lastblk

      END SUBROUTINE multrec_filtering_${nametype1}$
   #:endfor

END MODULE dbcsr_mm_multrec
