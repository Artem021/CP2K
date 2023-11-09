MODULE hremd_tools
   USE kinds,                           ONLY: default_string_length,&
                                              dp
    implicit none

    public :: hremd
    private

    type :: hremd
      logical :: do_hremd
      logical :: external
      logical :: err
      real(dp), allocatable :: xyz(:, :, :)
      
      real(dp) :: alpha
      real(dp) :: alpha_ei
      real(dp) :: alpha_vdw

      integer :: nstruc
      real(dp) :: epot
      real(dp) :: eb
      real(dp) :: enb
      integer :: md_step
      integer :: md_max_step
    end type hremd
    
 contains

   subroutine test(arg1,arg2)
   logical, intent(in) :: arg1
   logical, intent(out) :: arg2
   write(*,*) "argument in: ", arg1
   write(*,*) "argument out, init: ", arg2
   if (arg2) then
      arg2=.false.
   else
      arg2=.true.
   end if
   write(*,*) "argument out, new: ", arg2
   end subroutine test

   END MODULE hremd_tools