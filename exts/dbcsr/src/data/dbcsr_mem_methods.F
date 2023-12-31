!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_mem_methods
   !! DBCSR Memory Pool to avoid slow allocations of accelerator memory

   USE dbcsr_acc_stream, ONLY: acc_stream_associated, &
                               acc_stream_equal, &
                               acc_stream_type
   USE dbcsr_data_methods_low, ONLY: dbcsr_data_exists, &
                                     dbcsr_data_get_size, &
                                     internal_data_deallocate
   USE dbcsr_data_types, ONLY: dbcsr_data_obj, &
                               dbcsr_mempool_entry_type, &
                               dbcsr_mempool_type, &
                               dbcsr_memtype_type
   USE dbcsr_kinds, ONLY: dp

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads, &
!$                    omp_set_lock, omp_unset_lock, omp_init_lock, omp_lock_kind, omp_destroy_lock

#include "base/dbcsr_base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_mem_methods'

   PUBLIC :: dbcsr_mempool_get, dbcsr_mempool_add, dbcsr_mempool_limit_capacity
   PUBLIC :: dbcsr_mempool_destruct, dbcsr_mempool_clear
   PUBLIC :: dbcsr_memtype_setup, dbcsr_memtype_equal

   LOGICAL, PARAMETER :: debug = .FALSE.

CONTAINS

   SUBROUTINE dbcsr_mempool_create(pool)
      !! Creates a memory pool.
      TYPE(dbcsr_mempool_type), POINTER                  :: pool

      IF (ASSOCIATED(pool)) DBCSR_ABORT("pool already allocated")
      ALLOCATE (pool)
!$    CALL OMP_INIT_LOCK(pool%lock)
      ALLOCATE (pool%root) !root always allocated, but unused. Simplifies looping.
   END SUBROUTINE dbcsr_mempool_create

   SUBROUTINE dbcsr_mempool_limit_capacity(pool, capacity)
      !! Ensures that mempool has at least the given capacity.
      TYPE(dbcsr_mempool_type), POINTER                  :: pool
      INTEGER, INTENT(IN)                                :: capacity

      IF (.NOT. ASSOCIATED(pool)) RETURN
!$    CALL OMP_SET_LOCK(pool%lock)
      pool%capacity = MAX(pool%capacity, capacity)
!$    CALL OMP_UNSET_LOCK(pool%lock)

   END SUBROUTINE dbcsr_mempool_limit_capacity

   FUNCTION dbcsr_mempool_get(memtype, datatype, datasize) RESULT(res)
      !! Picks a suitable data_area from mempool, returns Null() if none found.
      TYPE(dbcsr_memtype_type)                           :: memtype
      INTEGER, INTENT(IN)                                :: datatype, datasize
      TYPE(dbcsr_data_obj)                               :: res

      INTEGER                                            :: best_size, s
      TYPE(dbcsr_mempool_entry_type), POINTER            :: best_cur, best_prev, cur, prev
      TYPE(dbcsr_mempool_type), POINTER                  :: pool

      pool => memtype%pool
      IF (.NOT. ASSOCIATED(pool)) DBCSR_ABORT("pool not allocated")

!$    CALL OMP_SET_LOCK(pool%lock)
      res%d => Null()
      best_cur => Null()
      best_prev => Null()
      best_size = HUGE(1)
      prev => Null()
      cur => pool%root
      DO WHILE (ASSOCIATED(cur%next))
         prev => cur
         cur => cur%next
         s = dbcsr_data_get_size(cur%area)
         IF (s < datasize) CYCLE
         IF (.NOT. dbcsr_memtype_equal(cur%area%d%memory_type, memtype)) CYCLE
         IF (cur%area%d%data_type /= datatype) CYCLE
         !we found a match
         IF (s < best_size) THEN
            best_cur => cur
            best_prev => prev
            best_size = s
         END IF
      END DO

      IF (ASSOCIATED(best_cur)) THEN
         IF (best_cur%area%d%refcount /= 0) DBCSR_ABORT("refcount /= 0")
         best_cur%area%d%refcount = 1
         best_prev%next => best_cur%next
         res = best_cur%area
         DEALLOCATE (best_cur)
      END IF
!$    CALL OMP_UNSET_LOCK(pool%lock)

      IF (.NOT. ASSOCIATED(res%d)) &
         CALL mempool_collect_garbage(pool)
   END FUNCTION dbcsr_mempool_get

   SUBROUTINE dbcsr_mempool_add(area)
      !! Adds an unused (refcount==0) data_area to the pool.
      TYPE(dbcsr_data_obj)                               :: area

      TYPE(dbcsr_mempool_entry_type), POINTER            :: new_entry
      TYPE(dbcsr_mempool_type), POINTER                  :: pool

      pool => area%d%memory_type%pool
      IF (.NOT. ASSOCIATED(pool)) DBCSR_ABORT("pool not allocated")
      IF (.NOT. dbcsr_data_exists(area)) DBCSR_ABORT("area not allocated")
      IF (area%d%refcount /= 0) DBCSR_ABORT("refcount /= 0")

      CALL mempool_collect_garbage(pool)

!$    CALL OMP_SET_LOCK(pool%lock)
      ALLOCATE (new_entry)
      new_entry%area = area
      new_entry%next => pool%root%next
      pool%root%next => new_entry
!$    CALL OMP_UNSET_LOCK(pool%lock)
   END SUBROUTINE dbcsr_mempool_add

   SUBROUTINE mempool_collect_garbage(pool)
      !! Ensures that pool_size < max_size, e.g. that there is a free slot.
      TYPE(dbcsr_mempool_type), POINTER                  :: pool

      INTEGER                                            :: n
      TYPE(dbcsr_mempool_entry_type), POINTER            :: cur, prev

      IF (.NOT. ASSOCIATED(pool)) DBCSR_ABORT("pool not allocated")

!$    CALL OMP_SET_LOCK(pool%lock)
      prev => pool%root
      cur => pool%root%next
      n = 0
      DO WHILE (ASSOCIATED(cur))
         n = n + 1
         IF (n >= pool%capacity) THEN
            CALL internal_data_deallocate(cur%area%d)
            DEALLOCATE (cur%area%d)
            prev%next => cur%next
            DEALLOCATE (cur)
            cur => prev%next
         ELSE
            prev => cur
            cur => cur%next
         END IF
      END DO
!$    CALL OMP_UNSET_LOCK(pool%lock)
   END SUBROUTINE mempool_collect_garbage

   SUBROUTINE dbcsr_mempool_destruct(pool)
      !! Finalizes mempool, includes deallocation of all contained data_areas.
      TYPE(dbcsr_mempool_type), POINTER                  :: pool

      IF (.NOT. ASSOCIATED(pool)) DBCSR_ABORT("pool not allocated")

      CALL dbcsr_mempool_clear(pool)

!$    CALL OMP_DESTROY_LOCK(pool%lock)
      DEALLOCATE (pool%root)
      DEALLOCATE (pool)

   END SUBROUTINE dbcsr_mempool_destruct

   SUBROUTINE dbcsr_mempool_clear(pool)
      !! Deallocates all data_areas contained in given mempool.
      TYPE(dbcsr_mempool_type), POINTER                  :: pool

      CHARACTER(LEN=*), PARAMETER :: routineN = 'dbcsr_mempool_clear'

      INTEGER                                            :: handle
      TYPE(dbcsr_mempool_entry_type), POINTER            :: cur, prev

      IF (.NOT. ASSOCIATED(pool)) DBCSR_ABORT("pool not allocated")

      CALL timeset(routineN, handle)

!$    CALL OMP_SET_LOCK(pool%lock)
      cur => pool%root%next
      DO WHILE (ASSOCIATED(cur))
         CALL internal_data_deallocate(cur%area%d)
         DEALLOCATE (cur%area%d)
         prev => cur
         cur => cur%next
         DEALLOCATE (prev)
      END DO
      NULLIFY (pool%root%next)
!$    CALL OMP_UNSET_LOCK(pool%lock)

      CALL timestop(handle)
   END SUBROUTINE dbcsr_mempool_clear

   SUBROUTINE dbcsr_memtype_setup(memtype, acc_hostalloc, acc_devalloc, mpi, &
      !! Ensures that given memtype has requested settings.
                                  acc_stream, oversize_factor, has_pool)
      TYPE(dbcsr_memtype_type), INTENT(INOUT)            :: memtype
      LOGICAL, INTENT(IN), OPTIONAL                      :: acc_hostalloc, acc_devalloc, mpi
      TYPE(acc_stream_type), OPTIONAL                    :: acc_stream
      REAL(KIND=dp), OPTIONAL                            :: oversize_factor
      LOGICAL, INTENT(IN), OPTIONAL                      :: has_pool

      LOGICAL                                            :: is_ok, my_has_pool
      TYPE(dbcsr_memtype_type)                           :: aim

! variable aim is initialized with default values from type definition

      my_has_pool = .FALSE.
      IF (PRESENT(has_pool)) my_has_pool = has_pool
      IF (PRESENT(acc_hostalloc)) aim%acc_hostalloc = acc_hostalloc
      IF (PRESENT(acc_devalloc)) aim%acc_devalloc = acc_devalloc
      IF (PRESENT(mpi)) aim%mpi = mpi
      IF (PRESENT(acc_stream)) aim%acc_stream = acc_stream
      IF (PRESENT(oversize_factor)) aim%oversize_factor = oversize_factor

      IF (.NOT. aim%acc_devalloc .EQV. acc_stream_associated(aim%acc_stream)) &
         DBCSR_ABORT("acc_stream missing")

      is_ok = .TRUE.
      is_ok = is_ok .AND. (memtype%acc_hostalloc .EQV. aim%acc_hostalloc)
      is_ok = is_ok .AND. (memtype%acc_devalloc .EQV. aim%acc_devalloc)
      is_ok = is_ok .AND. (memtype%mpi .EQV. aim%mpi)
      is_ok = is_ok .AND. acc_stream_equal(memtype%acc_stream, aim%acc_stream)
      is_ok = is_ok .AND. (memtype%oversize_factor == aim%oversize_factor)
      is_ok = is_ok .AND. (ASSOCIATED(memtype%pool) .EQV. my_has_pool)

      IF (.NOT. is_ok) THEN
         IF (ASSOCIATED(memtype%pool)) &
            CALL dbcsr_mempool_destruct(memtype%pool)

         memtype%acc_hostalloc = aim%acc_hostalloc
         memtype%acc_devalloc = aim%acc_devalloc
         memtype%mpi = aim%mpi
         memtype%acc_stream = aim%acc_stream
         memtype%oversize_factor = aim%oversize_factor
         IF (my_has_pool) &
            CALL dbcsr_mempool_create(memtype%pool)
      END IF
   END SUBROUTINE dbcsr_memtype_setup

   FUNCTION dbcsr_memtype_equal(mt1, mt2) RESULT(res)
      !! Test if two memtypes are equal
      TYPE(dbcsr_memtype_type), INTENT(in)               :: mt1, mt2
      LOGICAL                                            :: res

      res = (mt1%mpi .EQV. mt2%mpi) .AND. &
            (mt1%acc_hostalloc .EQV. mt2%acc_hostalloc) .AND. &
            (mt1%acc_devalloc .EQV. mt2%acc_devalloc) .AND. &
            (ASSOCIATED(mt1%pool) .EQV. ASSOCIATED(mt2%pool)) .AND. &
            (.NOT. ASSOCIATED(mt1%pool) .OR. ASSOCIATED(mt1%pool, mt2%pool))
   END FUNCTION dbcsr_memtype_equal

END MODULE dbcsr_mem_methods
