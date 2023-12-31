!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_array_types
   !! Array objects with reference counting.

#include "base/dbcsr_base_uses.f90"
#if TO_VERSION(1, 11) <= TO_VERSION(LIBXSMM_CONFIG_VERSION_MAJOR, LIBXSMM_CONFIG_VERSION_MINOR)
   USE libxsmm, ONLY: libxsmm_diff
#  define PURE_ARRAY_EQUALITY
#else
#  define PURE_ARRAY_EQUALITY PURE
#endif

   IMPLICIT NONE
   PRIVATE

   PUBLIC :: array_i1d_obj
   PUBLIC :: array_new, &
             array_hold, &
             array_release, &
             array_nullify, &
             array_exists
   PUBLIC :: array_data, &
             array_size, &
             array_equality
   PUBLIC :: array_get

   INTERFACE array_new
      MODULE PROCEDURE array_new_i1d, array_new_i1d_lb
   END INTERFACE
   INTERFACE array_hold
      MODULE PROCEDURE array_hold_i1d
   END INTERFACE
   INTERFACE array_release
      MODULE PROCEDURE array_release_i1d
   END INTERFACE
   INTERFACE array_nullify
      MODULE PROCEDURE array_nullify_i1d
   END INTERFACE
   INTERFACE array_exists
      MODULE PROCEDURE array_exists_i1d
   END INTERFACE
   INTERFACE array_data
      MODULE PROCEDURE array_data_i1d
   END INTERFACE
   INTERFACE array_size
      MODULE PROCEDURE array_size_i1d
   END INTERFACE
   INTERFACE array_equality
      MODULE PROCEDURE array_equality_i1
      MODULE PROCEDURE array_equality_i1d
   END INTERFACE
   INTERFACE array_get
      MODULE PROCEDURE array_get_i1d
      MODULE PROCEDURE array_get_i1
   END INTERFACE

   TYPE array_i1d_type
      INTEGER, DIMENSION(:), POINTER, CONTIGUOUS :: DATA => Null()
      INTEGER                                    :: refcount = 0
   END TYPE array_i1d_type

   TYPE array_i1d_obj
      TYPE(array_i1d_type), POINTER      :: low => Null()
   END TYPE array_i1d_obj

CONTAINS

   SUBROUTINE array_new_i1d(array, DATA, gift)
      TYPE(array_i1d_obj), INTENT(OUT)                   :: array
      INTEGER, DIMENSION(:), POINTER, CONTIGUOUS         :: DATA
      LOGICAL, INTENT(IN), OPTIONAL                      :: gift

      INTEGER                                            :: lb, ub
      LOGICAL                                            :: g

      ALLOCATE (array%low)
      array%low%refcount = 1
      g = .FALSE.
      IF (PRESENT(gift)) g = gift
      IF (g) THEN
         array%low%data => DATA
         NULLIFY (DATA)
      ELSE
         lb = LBOUND(DATA, 1)
         ub = UBOUND(DATA, 1)
         ALLOCATE (array%low%data(lb:ub))
         array%low%data(:) = DATA(:)
      END IF
   END SUBROUTINE array_new_i1d

   SUBROUTINE array_new_i1d_lb(array, DATA, lb)
      TYPE(array_i1d_obj), INTENT(OUT)                   :: array
      INTEGER, DIMENSION(:), INTENT(IN)                  :: DATA
      INTEGER, INTENT(IN)                                :: lb

      INTEGER                                            :: ub

      ALLOCATE (array%low)
      array%low%refcount = 1
      ub = lb + SIZE(DATA) - 1
      ALLOCATE (array%low%data(lb:ub))
      array%low%data(:) = DATA(:)
   END SUBROUTINE array_new_i1d_lb

   SUBROUTINE array_hold_i1d(array)
      TYPE(array_i1d_obj), INTENT(INOUT)                 :: array
!$OMP ATOMIC
      array%low%refcount = array%low%refcount + 1
   END SUBROUTINE array_hold_i1d

   SUBROUTINE array_release_i1d(array)
      TYPE(array_i1d_obj), INTENT(INOUT)                 :: array

      IF (ASSOCIATED(array%low)) THEN
         array%low%refcount = array%low%refcount - 1
         IF (array%low%refcount .EQ. 0) THEN
            DEALLOCATE (array%low%data)
            DEALLOCATE (array%low)
         END IF
      END IF
   END SUBROUTINE array_release_i1d

   PURE SUBROUTINE array_nullify_i1d(array)
      TYPE(array_i1d_obj), INTENT(INOUT)                 :: array

      NULLIFY (array%low)
   END SUBROUTINE array_nullify_i1d

   PURE FUNCTION array_exists_i1d(array) RESULT(array_exists)
      TYPE(array_i1d_obj), INTENT(IN)                    :: array
      LOGICAL                                            :: array_exists

      array_exists = ASSOCIATED(array%low)
      IF (array_exists) array_exists = array%low%refcount .GT. 0
   END FUNCTION array_exists_i1d

   FUNCTION array_data_i1d(array) RESULT(DATA)
      TYPE(array_i1d_obj), INTENT(IN)                    :: array
      INTEGER, DIMENSION(:), POINTER, CONTIGUOUS         :: DATA

      IF (ASSOCIATED(array%low)) THEN
         DATA => array%low%data
      ELSE
         NULLIFY (DATA)
      END IF
   END FUNCTION array_data_i1d

   PURE FUNCTION array_size_i1d(array) RESULT(the_size)
      TYPE(array_i1d_obj), INTENT(IN)                    :: array
      INTEGER                                            :: the_size

      IF (ASSOCIATED(array%low)) THEN
         the_size = SIZE(array%low%data)
      ELSE
         the_size = 0
      END IF
   END FUNCTION array_size_i1d

   PURE_ARRAY_EQUALITY FUNCTION array_equality_i1(array1, array2) RESULT(are_equal)
      INTEGER, DIMENSION(:), POINTER, CONTIGUOUS         :: array1, array2
      LOGICAL                                            :: are_equal

      are_equal = .FALSE.
      IF (ASSOCIATED(array1) .AND. ASSOCIATED(array2)) THEN
#if TO_VERSION(1, 11) <= TO_VERSION(LIBXSMM_CONFIG_VERSION_MAJOR, LIBXSMM_CONFIG_VERSION_MINOR)
         are_equal = .NOT. libxsmm_diff(array1, array2)
#else
         IF (SIZE(array1) .NE. SIZE(array2)) RETURN
         are_equal = ALL(array1 .EQ. array2)
#endif
      END IF
   END FUNCTION array_equality_i1

   PURE_ARRAY_EQUALITY FUNCTION array_equality_i1d(array1, array2) RESULT(are_equal)
      TYPE(array_i1d_obj), INTENT(IN)                    :: array1, array2
      LOGICAL                                            :: are_equal

      are_equal = .FALSE.
      IF (ASSOCIATED(array1%low) .AND. ASSOCIATED(array2%low)) THEN
#if TO_VERSION(1, 11) <= TO_VERSION(LIBXSMM_CONFIG_VERSION_MAJOR, LIBXSMM_CONFIG_VERSION_MINOR)
         are_equal = .NOT. libxsmm_diff(array1%low%data, array2%low%data)
#else
         IF (SIZE(array1%low%data) .NE. SIZE(array2%low%data)) RETURN
         are_equal = ALL(array1%low%data .EQ. array2%low%data)
#endif
      END IF
   END FUNCTION array_equality_i1d

   PURE FUNCTION array_get_i1d(array, index1) RESULT(value)
      TYPE(array_i1d_obj), INTENT(IN)                    :: array
      INTEGER, INTENT(IN)                                :: index1
      INTEGER                                            :: value

      value = array%low%data(index1)
   END FUNCTION array_get_i1d

   PURE FUNCTION array_get_i1(array, index1) RESULT(value)
      INTEGER, DIMENSION(:), INTENT(IN), POINTER         :: array
      INTEGER, INTENT(IN)                                :: index1
      INTEGER                                            :: value

      value = array(index1)
   END FUNCTION array_get_i1
END MODULE dbcsr_array_types
