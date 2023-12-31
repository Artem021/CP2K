!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

#:include 'dbcsr_list.fypp'
MODULE dbcsr_list
   !! An array-based list which grows on demand.
   !! When the internal array is full, a new array of twice the size will be
   !! allocated and the items are copied over.
   !! This list can also be used as a stack.
   !! Have look at list_push(), list_pop() and list_peek().
   !! @note it's not possible to put all templates in a single module because this would lead to circular
   !! dependencies (timer_env_type contains list_routinestat_type and list_callstackentry_type, and
   !! list_timerenv_type contains timer_env_type)

   USE dbcsr_timings_base_type, ONLY: ${uselist(usetimingsbase)}$
   USE dbcsr_list_callstackentry, ONLY: @{uselist_listmethods(callstackentry)}@
   USE dbcsr_list_routinereport, ONLY: @{uselist_listmethods(routinereport)}@
   USE dbcsr_list_routinestat, ONLY: @{uselist_listmethods(routinestat)}@
   USE dbcsr_list_timerenv, ONLY: @{uselist_listmethods(timerenv)}@

#include "base/dbcsr_base_uses.f90"
   IMPLICIT NONE

   PRIVATE
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_list'

   PUBLIC :: list_init, list_isready, list_push, list_pop, list_peek, &
             list_get, list_size, list_destroy

   #:for vtype in valuetype
      PUBLIC :: list_${vtype}$_type
   #:endfor

   INTERFACE list_init
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_init
      #:endfor
   END INTERFACE

   INTERFACE list_isready
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_isready
      #:endfor
   END INTERFACE

   INTERFACE list_push
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_push
      #:endfor
   END INTERFACE

   INTERFACE list_pop
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_pop
      #:endfor
   END INTERFACE

   INTERFACE list_peek
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_peek
      #:endfor
   END INTERFACE

   INTERFACE list_insert
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_insert
      #:endfor
   END INTERFACE

   INTERFACE list_set
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_set
      #:endfor
   END INTERFACE

   INTERFACE list_get
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_get
      #:endfor
   END INTERFACE

   INTERFACE list_del
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_del
      #:endfor
   END INTERFACE

   INTERFACE list_clear
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_clear
      #:endfor
   END INTERFACE

   INTERFACE list_size
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_size
      #:endfor
   END INTERFACE

   INTERFACE list_destroy
      #:for vtype in valuetype
         MODULE PROCEDURE list_${vtype}$_destroy
      #:endfor
   END INTERFACE

END MODULE dbcsr_list
