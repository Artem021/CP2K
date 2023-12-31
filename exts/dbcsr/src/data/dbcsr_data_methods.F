!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_data_methods
   !! DBCSR data methods
   USE dbcsr_acc_devmem, ONLY: acc_devmem_allocate_bytes, &
                               acc_devmem_allocated, &
                               acc_devmem_dev2host, &
                               acc_devmem_ensure_size_bytes, &
                               acc_devmem_host2dev, &
                               acc_devmem_setzero_bytes, &
                               acc_devmem_size_in_bytes
   USE dbcsr_acc_event, ONLY: acc_event_record
   USE dbcsr_data_methods_low, ONLY: &
      dbcsr_data_clear_pointer, dbcsr_data_exists, dbcsr_data_get_memory_type, &
      dbcsr_data_get_size, dbcsr_data_get_size_referenced, dbcsr_data_get_sizes, &
      dbcsr_data_get_type, dbcsr_data_hold, dbcsr_data_init, dbcsr_data_set_pointer, &
      dbcsr_data_set_size_referenced, dbcsr_data_valid, dbcsr_data_zero, dbcsr_get_data, &
      dbcsr_get_data_p, dbcsr_get_data_p_c, dbcsr_get_data_p_d, dbcsr_get_data_p_s, &
      dbcsr_get_data_p_z, dbcsr_scalar, dbcsr_scalar_are_equal, dbcsr_scalar_fill_all, &
      dbcsr_scalar_get_type, dbcsr_scalar_get_value, dbcsr_scalar_negative, dbcsr_scalar_one, &
      dbcsr_scalar_set_type, dbcsr_scalar_zero, dbcsr_type_1d_to_2d, dbcsr_type_2d_to_1d, &
      dbcsr_type_is_2d, internal_data_allocate, internal_data_deallocate, dbcsr_scalar_multiply
   USE dbcsr_data_types, ONLY: &
      dbcsr_data_obj, dbcsr_datatype_sizeof, dbcsr_memtype_default, dbcsr_memtype_type, &
      dbcsr_type_complex_4, dbcsr_type_complex_8, dbcsr_type_int_4, dbcsr_type_int_8, &
      dbcsr_type_real_4, dbcsr_type_real_8
   USE dbcsr_kinds, ONLY: dp, &
                          int_4, &
                          int_8, &
                          real_4, &
                          real_8
   USE dbcsr_mem_methods, ONLY: dbcsr_mempool_add, &
                                dbcsr_mempool_get
   USE dbcsr_ptr_util, ONLY: ensure_array_size
#include "base/dbcsr_base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_data_methods'
   LOGICAL, PARAMETER :: careful_mod = .FALSE.

   INTEGER, SAVE                        :: id = 0

   PUBLIC :: dbcsr_type_2d_to_1d, dbcsr_type_1d_to_2d
   PUBLIC :: dbcsr_scalar, dbcsr_scalar_one, dbcsr_scalar_zero, &
             dbcsr_scalar_are_equal, dbcsr_scalar_negative, &
             dbcsr_scalar_get_type, dbcsr_scalar_set_type, &
             dbcsr_scalar_fill_all, dbcsr_scalar_get_value, &
             dbcsr_data_valid, dbcsr_data_exists, dbcsr_scalar_multiply
   PUBLIC :: dbcsr_data_init, dbcsr_data_new, dbcsr_data_hold, &
             dbcsr_data_release, dbcsr_data_get_size, dbcsr_data_get_type
   PUBLIC :: dbcsr_get_data, &
             dbcsr_data_set_pointer, &
             dbcsr_data_clear_pointer, &
             dbcsr_data_ensure_size, &
             dbcsr_data_get_sizes, &
             dbcsr_data_get_memory_type
   PUBLIC :: dbcsr_data_set_size_referenced, dbcsr_data_get_size_referenced
   PUBLIC :: dbcsr_get_data_p, dbcsr_get_data_p_s, dbcsr_get_data_p_c, &
             dbcsr_get_data_p_d, dbcsr_get_data_p_z
   PUBLIC :: dbcsr_data_host2dev, dbcsr_data_dev2host

CONTAINS

   SUBROUTINE dbcsr_data_host2dev(area)
      !! Transfers data from host- to device-buffer, asynchronously.
      TYPE(dbcsr_data_obj), INTENT(INOUT)                :: area

      COMPLEX(KIND=real_4), DIMENSION(:), POINTER        :: c_sp
      COMPLEX(KIND=real_8), DIMENSION(:), POINTER        :: c_dp
      INTEGER(KIND=int_4), DIMENSION(:), POINTER         :: i4
      INTEGER(KIND=int_8), DIMENSION(:), POINTER         :: i8
      REAL(KIND=real_4), DIMENSION(:), POINTER           :: r_sp
      REAL(KIND=real_8), DIMENSION(:), POINTER           :: r_dp

      IF (.NOT. acc_devmem_allocated(area%d%acc_devmem)) RETURN !nothing to do
      IF (area%d%ref_size == 0) RETURN !nothing to do

      SELECT CASE (area%d%data_type)
      CASE (dbcsr_type_int_4)
         i4 => area%d%i4(:area%d%ref_size)
         CALL acc_devmem_host2dev(area%d%acc_devmem, hostmem=i4, stream=area%d%memory_type%acc_stream)
      CASE (dbcsr_type_int_8)
         i8 => area%d%i8(:area%d%ref_size)
         CALL acc_devmem_host2dev(area%d%acc_devmem, hostmem=i8, stream=area%d%memory_type%acc_stream)
      CASE (dbcsr_type_real_4)
         r_sp => area%d%r_sp(:area%d%ref_size)
         CALL acc_devmem_host2dev(area%d%acc_devmem, hostmem=r_sp, stream=area%d%memory_type%acc_stream)
      CASE (dbcsr_type_real_8)
         r_dp => area%d%r_dp(:area%d%ref_size)
         CALL acc_devmem_host2dev(area%d%acc_devmem, hostmem=r_dp, stream=area%d%memory_type%acc_stream)
      CASE (dbcsr_type_complex_4)
         c_sp => area%d%c_sp(:area%d%ref_size)
         CALL acc_devmem_host2dev(area%d%acc_devmem, hostmem=c_sp, stream=area%d%memory_type%acc_stream)
      CASE (dbcsr_type_complex_8)
         c_dp => area%d%c_dp(:area%d%ref_size)
         CALL acc_devmem_host2dev(area%d%acc_devmem, hostmem=c_dp, stream=area%d%memory_type%acc_stream)
      CASE default
         DBCSR_ABORT("Invalid data type.")
      END SELECT

      CALL acc_event_record(area%d%acc_ready, area%d%memory_type%acc_stream)
   END SUBROUTINE dbcsr_data_host2dev

   SUBROUTINE dbcsr_data_dev2host(area)
      !! Transfers data from device- to host-buffer, asynchronously.
      TYPE(dbcsr_data_obj), INTENT(INOUT)                :: area

      COMPLEX(KIND=real_4), DIMENSION(:), POINTER        :: c_sp
      COMPLEX(KIND=real_8), DIMENSION(:), POINTER        :: c_dp
      REAL(KIND=real_4), DIMENSION(:), POINTER           :: r_sp
      REAL(KIND=real_8), DIMENSION(:), POINTER           :: r_dp

      IF (area%d%ref_size == 0) RETURN !nothing to do

      SELECT CASE (area%d%data_type)
      CASE (dbcsr_type_real_4)
         r_sp => area%d%r_sp(:area%d%ref_size)
         CALL acc_devmem_dev2host(area%d%acc_devmem, hostmem=r_sp, stream=area%d%memory_type%acc_stream)
      CASE (dbcsr_type_real_8)
         r_dp => area%d%r_dp(:area%d%ref_size)
         CALL acc_devmem_dev2host(area%d%acc_devmem, hostmem=r_dp, stream=area%d%memory_type%acc_stream)
      CASE (dbcsr_type_complex_4)
         c_sp => area%d%c_sp(:area%d%ref_size)
         CALL acc_devmem_dev2host(area%d%acc_devmem, hostmem=c_sp, stream=area%d%memory_type%acc_stream)
      CASE (dbcsr_type_complex_8)
         c_dp => area%d%c_dp(:area%d%ref_size)
         CALL acc_devmem_dev2host(area%d%acc_devmem, hostmem=c_dp, stream=area%d%memory_type%acc_stream)
      CASE default
         DBCSR_ABORT("Invalid data type.")
      END SELECT

   END SUBROUTINE dbcsr_data_dev2host

   SUBROUTINE dbcsr_data_new(area, data_type, data_size, data_size2, &
                             memory_type)
      !! Initializes a data area and all the actual data pointers

      TYPE(dbcsr_data_obj), INTENT(INOUT)                :: area
         !! data area
      INTEGER, INTENT(IN)                                :: data_type
         !! select data type to use
      INTEGER, INTENT(IN), OPTIONAL                      :: data_size, data_size2
         !! allocate this much data
         !! second dimension data size
      TYPE(dbcsr_memtype_type), INTENT(IN), OPTIONAL     :: memory_type
         !! type of memory to use

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_data_new'
      INTEGER                                            :: d, handle, total_size_oversized, &
                                                            total_size_requested
      INTEGER, DIMENSION(2)                              :: sizes_oversized, sizes_requested
      TYPE(dbcsr_memtype_type)                           :: my_memory_type

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, handle)

      IF (ASSOCIATED(area%d)) &
         DBCSR_ABORT("area already associated")

      my_memory_type = dbcsr_memtype_default
      IF (PRESENT(memory_type)) my_memory_type = memory_type

      sizes_requested(:) = 0; d = 1
      IF (PRESENT(data_size)) sizes_requested(1) = data_size

      IF (dbcsr_type_is_2d(data_type)) THEN
         d = 2
         IF (PRESENT(data_size2)) sizes_requested(2) = data_size2

         IF (PRESENT(data_size) .NEQV. PRESENT(data_size2)) &
            DBCSR_ABORT("Must specify 2 sizes for 2-D data")
      END IF

      sizes_oversized = INT(sizes_requested*my_memory_type%oversize_factor)
      total_size_requested = PRODUCT(sizes_requested(1:d))
      total_size_oversized = PRODUCT(sizes_oversized(1:d))

      IF (ANY(sizes_requested < 0) .OR. ANY(sizes_oversized < 0)) &
         DBCSR_ABORT("Negative data size requested, integer overflow?")

      IF (total_size_requested > 1 .AND. ASSOCIATED(my_memory_type%pool)) THEN
         area = dbcsr_mempool_get(my_memory_type, data_type, total_size_requested)
      END IF

      IF (.NOT. ASSOCIATED(area%d)) THEN
         ALLOCATE (area%d)
!$OMP        CRITICAL (crit_area_id)
         id = id + 1
         area%d%id = id
!$OMP        END CRITICAL (crit_area_id)
         area%d%refcount = 1
         area%d%memory_type = my_memory_type
         area%d%data_type = data_type
         IF (PRESENT(data_size)) THEN
            CALL internal_data_allocate(area%d, sizes_oversized(1:d))
         END IF
      END IF

      area%d%ref_size = total_size_requested

      CALL timestop(handle)
   END SUBROUTINE dbcsr_data_new

   SUBROUTINE dbcsr_data_ensure_size(area, data_size, nocopy, zero_pad, factor, &
                                     area_resize)
      !! Ensures a minimum size of a previously-setup data area.
      !! The data area must have been previously setup with dbcsr_data_new.

      TYPE(dbcsr_data_obj), INTENT(INOUT)                :: area
         !! data area
      INTEGER, INTENT(IN)                                :: data_size
         !! allocate this much data
      LOGICAL, INTENT(IN), OPTIONAL                      :: nocopy, zero_pad
         !! do not keep potentially existing data, default is to keep it
         !! pad new data with zeros
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: factor
         !! increase size by this factor
      TYPE(dbcsr_data_obj), INTENT(INOUT), OPTIONAL      :: area_resize

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_data_ensure_size'

      INTEGER                                            :: current_size, handle, wanted_size
      LOGICAL                                            :: nocp, pad
      TYPE(dbcsr_data_obj)                               :: area_tmp

!   ---------------------------------------------------------------------------

      IF (careful_mod) CALL timeset(routineN, handle)
      IF (.NOT. ASSOCIATED(area%d)) &
         DBCSR_ABORT("Data area must be setup.")
      current_size = dbcsr_data_get_size(area)

      IF (PRESENT(area_resize)) THEN
         ! Sanity check
         IF (.NOT. dbcsr_data_valid(area_resize)) &
            DBCSR_ABORT("Previous data area must be setup.")
         IF (dbcsr_data_exists(area_resize)) &
            DBCSR_ABORT("Previous data area must be not associated.")
         IF (area%d%memory_type%acc_devalloc) &
            DBCSR_ABORT("Cannot use dev memory with previous data area.")
         IF (ASSOCIATED(area%d%memory_type%pool)) &
            DBCSR_ABORT("Cannot use memory pool with previous data area.")
      END IF

      wanted_size = data_size
#if defined(__HAS_smm_dnn) && defined(__HAS_smm_vec)
      ! allocate some more as padding for libsmm kernels which read over the end.
      IF (data_size .GT. 0) THEN
         wanted_size = data_size + 10
      END IF
#endif

      !IF(area%d%memory_type%acc_devalloc) THEN
      !    IF(current_size==acc_devmem_size(area%d%acc_devmem)) &
      !      WRITE (*,*) "dbcsr_data_ensure_size: Host and device buffer differ in size."
      !END IF
      !IF(current_size/=acc_devmem_size(area%d%acc_devmem)) &
      !   DBCSR_ABORT("Host and device buffer differ in size.")

      CALL dbcsr_data_set_size_referenced(area, data_size)
      IF (current_size .GT. 1 .AND. current_size .GE. wanted_size) THEN
         IF (careful_mod) CALL timestop(handle)
         RETURN
      END IF
      !
      nocp = .FALSE.
      IF (PRESENT(nocopy)) nocp = nocopy
      pad = .FALSE.
      IF (PRESENT(zero_pad)) pad = zero_pad

      IF (dbcsr_data_exists(area)) THEN
         IF (nocp .AND. dbcsr_data_get_size(area) <= 1) THEN
            IF (PRESENT(area_resize)) THEN
               CALL dbcsr_data_set_pointer(area_resize, &
                                           dbcsr_data_get_size(area), 1, area)
               CALL dbcsr_data_clear_pointer(area)
            ELSE
               CALL internal_data_deallocate(area%d)
            END IF
         END IF
      END IF

      IF (.NOT. dbcsr_data_exists(area)) THEN
         IF (ASSOCIATED(area%d%memory_type%pool)) THEN
            area_tmp = dbcsr_mempool_get(area%d%memory_type, area%d%data_type, wanted_size)
            IF (ASSOCIATED(area_tmp%d)) THEN
               area_tmp%d%ref_size = wanted_size
               area_tmp%d%refcount = area%d%refcount
               DEALLOCATE (area%d)
               area = area_tmp
            END IF
         END IF

         IF (.NOT. dbcsr_data_exists(area)) &
            CALL internal_data_allocate(area%d, (/wanted_size/))

         IF (pad) CALL dbcsr_data_zero(area, (/1/), (/wanted_size/))
      ELSE
         SELECT CASE (area%d%data_type)
         CASE (dbcsr_type_int_8)
            IF (PRESENT(area_resize)) THEN
               CALL ensure_array_size(area%d%i8, &
                                      array_resize=area_resize%d%i8, &
                                      ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            ELSE
               CALL ensure_array_size(area%d%i8, ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            END IF
         CASE (dbcsr_type_int_4)
            IF (PRESENT(area_resize)) THEN
               CALL ensure_array_size(area%d%i4, &
                                      array_resize=area_resize%d%i4, &
                                      ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            ELSE
               CALL ensure_array_size(area%d%i4, ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            END IF
         CASE (dbcsr_type_real_8)
            IF (PRESENT(area_resize)) THEN
               CALL ensure_array_size(area%d%r_dp, &
                                      array_resize=area_resize%d%r_dp, &
                                      ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            ELSE
               CALL ensure_array_size(area%d%r_dp, ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            END IF
         CASE (dbcsr_type_real_4)
            IF (PRESENT(area_resize)) THEN
               CALL ensure_array_size(area%d%r_sp, &
                                      array_resize=area_resize%d%r_sp, &
                                      ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            ELSE
               CALL ensure_array_size(area%d%r_sp, ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            END IF
         CASE (dbcsr_type_complex_8)
            IF (PRESENT(area_resize)) THEN
               CALL ensure_array_size(area%d%c_dp, &
                                      array_resize=area_resize%d%c_dp, &
                                      ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            ELSE
               CALL ensure_array_size(area%d%c_dp, ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            END IF
         CASE (dbcsr_type_complex_4)
            IF (PRESENT(area_resize)) THEN
               CALL ensure_array_size(area%d%c_sp, &
                                      array_resize=area_resize%d%c_sp, &
                                      ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            ELSE
               CALL ensure_array_size(area%d%c_sp, ub=wanted_size, &
                                      memory_type=area%d%memory_type, &
                                      nocopy=nocp, zero_pad=zero_pad, &
                                      factor=factor)
            END IF
         CASE default
            DBCSR_ABORT("Invalid data type are supported")
         END SELECT

         IF (area%d%memory_type%acc_devalloc) THEN
            IF (.NOT. acc_devmem_allocated(area%d%acc_devmem)) THEN
               CALL acc_devmem_allocate_bytes(area%d%acc_devmem, &
                                              dbcsr_datatype_sizeof(area%d%data_type)*dbcsr_data_get_size(area))
               IF (pad) CALL acc_devmem_setzero_bytes(area%d%acc_devmem, stream=area%d%memory_type%acc_stream)
            ELSE
               CALL acc_devmem_ensure_size_bytes(area%d%acc_devmem, &
                                                 area%d%memory_type%acc_stream, &
                                                 dbcsr_datatype_sizeof(area%d%data_type)*dbcsr_data_get_size(area), &
                                                 nocopy, zero_pad)
            END IF
            CALL acc_event_record(area%d%acc_ready, area%d%memory_type%acc_stream)
            IF (dbcsr_datatype_sizeof(area%d%data_type)*dbcsr_data_get_size(area) &
                /= acc_devmem_size_in_bytes(area%d%acc_devmem)) &
               DBCSR_ABORT("Host and device buffer differ in size.")
         END IF

      END IF
      IF (careful_mod) CALL timestop(handle)
   END SUBROUTINE dbcsr_data_ensure_size

   SUBROUTINE dbcsr_data_release(area)
      !! Removes a reference and/or clears the data area.

      TYPE(dbcsr_data_obj), INTENT(INOUT)                :: area
         !! data area

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_data_release'

      INTEGER                                            :: handle

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, handle)

      IF (.NOT. ASSOCIATED(area%d)) &
         DBCSR_WARN("Data seems to be unreferenced.")
      IF (ASSOCIATED(area%d)) THEN
         !
         IF (careful_mod) THEN
            IF (area%d%refcount .LE. 0) &
               DBCSR_WARN("Data seems to be unreferenced.")
         END IF
         !
         area%d%refcount = area%d%refcount - 1
         ! If we're releasing the last reference, then free the memory.
         IF (area%d%refcount .EQ. 0) THEN
            IF (.NOT. dbcsr_data_exists(area)) THEN
               DEALLOCATE (area%d)
            ELSE IF (dbcsr_data_get_size(area) > 1 .AND. ASSOCIATED(area%d%memory_type%pool)) THEN
               area%d%ref_size = 0
               CALL dbcsr_mempool_add(area)
            ELSE
               CALL internal_data_deallocate(area%d)
               DEALLOCATE (area%d)
            END IF
            NULLIFY (area%d)
         END IF
      END IF

      CALL timestop(handle)

   END SUBROUTINE dbcsr_data_release

END MODULE dbcsr_data_methods
