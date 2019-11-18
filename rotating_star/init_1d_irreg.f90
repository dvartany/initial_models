!!  Take an initial model from a Lagrangian code and put it onto
!!  a uniform grid and make sure that it is happy with the EOS in
!!  our code.  The output is a .hse file that can be read directly
!!  by Maestro.
!!
!!  The model is placed into HSE by the following differencing:
!!
!!   (1/dr) [ <P>_i - <P>_{i-1} ] = (1/2) [ <rho>_i + <rho>_{i-1} ] g
!!
!!
!!  We take the temperature structure directly from the original
!!  initial model.  We adjust the density and pressure according to
!!  HSE using the EOS.
!!
!!***

program init_1d_irreg

  use bl_types
  use bl_constants_module
  use bl_error_module
  use eos_module, only: eos, eos_init
  use eos_type_module, only : eos_t, eos_input_rt
  use network
  use fundamental_constants_module
  use extern_probin_module, only: use_eos_coulomb

  implicit none

  integer :: i, j, n

  real (kind=dp_t), allocatable :: xzn_hse(:), xznl(:), xznr(:)
  real (kind=dp_t), allocatable :: M_enclosed(:)
  real (kind=dp_t), allocatable :: model_mesa_hse(:,:)
  real (kind=dp_t), allocatable :: model_isentropic_hse(:,:)
  real (kind=dp_t), allocatable :: model_hybrid_hse(:,:)
  real (kind=dp_t), allocatable :: entropy_want(:)

  integer, parameter :: nx = 640
  integer, parameter :: nr = (3*((nx/5)/2-0.5_dp_t)*((nx/5)/2-0.5_dp_t)-0.75_dp_t)/2.0_dp_t;

  ! define convenient indices for the scalars
  integer, parameter :: nvar = 5 + nspec
  integer, parameter :: idens = 1, &
                        itemp = 2, &
                        ipres = 3, &
                        ientr = 4, &
                        ienuc = 5, &
                        ispec = 6
                     !    isndspd = 5, &
                     !    imass = 6, &
                     !    igradr = 7, &
                     !    igrav = 8, &
                     !    ibrunt = 9, &
                     !    iconv_vel = 10, &
                     !    ispec = 11

  real (kind=dp_t), save :: xmin, xmax, delx, delr
  real (kind=dp_t), allocatable :: delrl(:), delrr(:)

  real (kind=dp_t) :: dens_zone, temp_zone, pres_zone, entropy

  real (kind=dp_t) :: A, B, dAdT, dAdrho, dBdT, dBdrho
  real (kind=dp_t) :: dpd, dpt, dsd, dst

  real (kind=dp_t) :: central_density

  real (kind=dp_t) :: p_want, drho, dtemp

  real (kind=dp_t) :: g_zone

  real (kind=dp_t) :: max_hse_error, dpdr, rhog

  real (kind=dp_t), parameter :: TOL = 1.e-10

  integer, parameter :: MAX_ITER = 250

  integer :: iter, iter_dens, status

  integer :: igood
  real (kind=dp_t) :: slope

  logical :: converged_hse, converged_central_density, fluff, isentropic

  real (kind=dp_t) :: max_temp

  integer :: index_hse_fluff

  real (kind=dp_t), dimension(nspec) :: xn

  real (kind=dp_t), save :: low_density_cutoff, temp_fluff, temp_fluff_cutoff, smallx

  integer, parameter :: MAX_VARNAME_LENGTH=80
  integer :: npts_model, nvars_model_file

  real(kind=dp_t), allocatable :: base_state(:,:), base_r(:)
  real(kind=dp_t), allocatable :: vars_stored(:)
  character(len=MAX_VARNAME_LENGTH), allocatable :: varnames_stored(:)
  logical :: found

  integer :: ipos
  character (len=256) :: header_line, model_file
  logical :: mesa
  character (len=500) :: outfile, model_name
  character (len=8) :: num

  real(kind=dp_t) :: sum
  real(kind=dp_t) :: rfrac

  integer :: ibegin
  integer :: i_isentropic

  real(kind=dp_t) :: anelastic_cutoff = 9.e4  ! this is for diagnostics only -- not used in the HSEing
  real(kind=dp_t) :: M_enclosed_anel
  real(kind=dp_t) :: grav_ener, M_center
  real(kind=dp_t) :: eint_hybrid

  type (eos_t) :: eos_state

  smallx = 1.d-10

  ! set the parameters
  ! model_file = "18m_500_s_rot_b_eq_1.dat"
  ! mesa = .true.
  model_file = "15m_500_sec.txt"
  mesa = .false.

  xmin = 0_dp_t
  xmax = 5.d9

  low_density_cutoff = 1.d-4

  ! temp_fluff_cutoff is the density below which we hold the temperature
  ! constant for the kepler model

  ! MAESTRO
  temp_fluff_cutoff = 1.d-4

  ! CASTRO
  ! temp_fluff_cutoff = 1.d3

  temp_fluff = 1.d5

  ! this comes in via extern_probin_module -- override the default
  ! here if we want
  use_eos_coulomb = .true.


  ! initialize the EOS and network
  call eos_init()
  call network_init()

  !===========================================================================
  ! Create a 1-d uniform grid that is identical to the mesh that we are
  ! mapping onto, and then we want to force it into HSE on that mesh.
  !===========================================================================

  ! allocate storage
  allocate(xzn_hse(nr))
  allocate(xznl(nr))
  allocate(xznr(nr))
  allocate(model_mesa_hse(nr,nvar))
  allocate(model_isentropic_hse(nr,nvar))
  allocate(model_hybrid_hse(nr,nvar))
  allocate(M_enclosed(nr))
  allocate(entropy_want(nr))
  allocate(delrl(nr))
  allocate(delrr(nr))

  ! compute the coordinates of the new gridded function
  delx = (xmax - xmin) / dble(nx/5)

  do i = 1, nr
     if (i .eq. 1) then
        ! set the first edge node to xmin
        xznl(i) = xmin
     else
        xznl(i) = xmin + sqrt(0.75_dp_t + 2.0_dp_t*(i - 1.5_dp_t))*delx
     end if

     xznr(i) = xmin + sqrt(0.75_dp_t + 2.0_dp_t*(i - 0.5_dp_t))*delx
     xzn_hse(i) =  xmin + sqrt( 0.75_dp_t + 2.0_dp_t*(i - 1.0_dp_t) )*delx  ! cell center
     delrl(i) = xzn_hse(i) - xznl(i) 
     delrr(i) = xznr(i) - xzn_hse(i)
  enddo



  !===========================================================================
  ! read in the MESA model
  !===========================================================================

  if (mesa) then 

    allocate(varnames_stored(nvar-nspec))
    varnames_stored(idens) = "rho"
    varnames_stored(itemp) = "temperature"
    varnames_stored(ipres) = "pressure"
    varnames_stored(ientr) = "entropy"
    ! varnames_stored(isndspd) = "csound"
    ! varnames_stored(imass) = "mass"
    ! varnames_stored(igradr) = "gradT"
    ! varnames_stored(igrav) = "grav"
    ! varnames_stored(ibrunt) = "brunt_N2"
    ! varnames_stored(iconv_vel) = "conv_vel"

    call read_mesa(model_file, base_state, base_r, varnames_stored, nvar-nspec, npts_model)

  else 

    allocate(varnames_stored(nvar-nspec))
    varnames_stored(idens) = "dens"
    varnames_stored(itemp) = "temp"
    varnames_stored(ipres) = "pres"
    varnames_stored(ientr) = "entr"
    varnames_stored(ienuc) = "enuc"

    call read_file(model_file, base_state, base_r, varnames_stored, nvar-nspec, npts_model)

  endif


  !===========================================================================
  ! put the model onto our new nonuniform grid
  !===========================================================================

  igood = -1

  do i = 1, nr

     do n = 1, nvar

        if (xzn_hse(i) < base_r(npts_model)) then

           model_mesa_hse(i,n) = interpolate(xzn_hse(i), npts_model, &
                                        base_r, base_state(:,n))

           igood = i
        else

           !if (n == itemp) then

              ! linearly interpolate the last good MESA zones
           !   slope = (model_mesa_hse(igood,itemp) - model_mesa_hse(igood-1,itemp))/ &
           !        (xzn_hse(igood) - xzn_hse(igood-1))
           !
           !   model_mesa_hse(i,n) = max(temp_fluff, &
           !                               model_mesa_hse(igood,itemp) + slope*(xzn_hse(i) - xzn_hse(igood)))

           !else
              ! use a zero-gradient at the top of the initial model if our domain is
              ! larger than the model's domain.

              model_mesa_hse(i,n) = base_state(npts_model,n)
           !endif
        endif

     enddo


     ! make sure that the species (mass fractions) sum to 1
     sum = 0.0_dp_t
     do n = ispec,ispec-1+nspec
        model_mesa_hse(i,n) = max(model_mesa_hse(i,n),smallx)
        sum = sum + model_mesa_hse(i,n)
     enddo

     do n = ispec,ispec-1+nspec
        model_mesa_hse(i,n) = model_mesa_hse(i,n)/sum
     enddo

  enddo



  open (unit=30, file="model.nonuniform", status="unknown")

1000 format (1x, 12(g26.16, 1x))

  write (30,*) "# initial model just after putting onto a non-uniform grid"

  do i = 1, nr

     if (mesa) then 

    !  write (30,1000) xzn_hse(i), model_mesa_hse(i,idens), model_mesa_hse(i,itemp), &
    !       model_mesa_hse(i,ipres), model_mesa_hse(i,iconv_vel), (model_mesa_hse(i,ispec-1+n), n=1,nspec)

     else
        
        write (30,1000) xzn_hse(i), model_mesa_hse(i,idens), model_mesa_hse(i,itemp), &
             model_mesa_hse(i,ipres), (model_mesa_hse(i,ispec-1+n), n=1,nspec)

     endif

  enddo

  close (unit=30)

  !===========================================================================
  ! iterate to find the central density
  !===========================================================================

  ! because the MESA model likely begins at a larger radius than our first
  ! HSE model zone, simple interpolation will not do a good job.  We want to
  ! integrate in from the zone that best matches the first Mesa model zone,
  ! assuming HSE and constant entropy.


  ! find the zone in the nonconstant gridded model that corresponds to the
  ! first zone of the original model
  ibegin = -1
  do i = 1, nr
     if (xzn_hse(i) >= base_r(1)) then
        ibegin = i
        exit
     endif
  enddo

  print *, 'ibegin = ', ibegin


  ! store the central density.  We will iterate until the central density
  ! converges
  central_density = model_mesa_hse(1,idens)
  print *, 'interpolated central density = ', central_density

  delr = delrl(1) + delrr(1)
  
  do iter_dens = 1, max_iter

     ! compute the enclosed mass
     M_enclosed(1) = FOUR3RD*M_PI*delr**3*model_mesa_hse(1,idens)

     do i = 2, ibegin
        M_enclosed(i) = M_enclosed(i-1) + &
             FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
             (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_mesa_hse(i,idens)
     enddo


     ! now start at ibegin and integrate inward
     eos_state%T     = model_mesa_hse(ibegin,itemp)
     eos_state%rho   = model_mesa_hse(ibegin,idens)
     eos_state%xn(:) = model_mesa_hse(ibegin,ispec:nvar)

     call eos(eos_input_rt, eos_state)

     model_mesa_hse(ibegin,ipres) = eos_state%p
     ! model_mesa_hse(ibegin,ientr) = eos_state%s
     ! model_mesa_hse(ibegin,isndspd) = &
     !      sqrt(eos_state%gam1*eos_state%p/eos_state%rho)

     entropy_want(:) = eos_state%s


     do i = ibegin-1, 1, -1


        ! as the initial guess for the temperature and density, use
        ! the previous zone
        dens_zone = model_mesa_hse(i+1,idens)
        temp_zone = model_mesa_hse(i+1,itemp)
        xn(:) = model_mesa_hse(i,ispec:nvar)

        ! compute the gravitational acceleration on the interface between zones
        ! i and i+1
        g_zone = -Gconst*M_enclosed(i)/(xznr(i)*xznr(i))


        !-----------------------------------------------------------------------
        ! iteration loop
        !-----------------------------------------------------------------------

        ! start off the Newton loop by saying that the zone has not converged
        converged_hse = .FALSE.

        delr = delrr(i) + delrl(i+1)
        rfrac = delrl(i+1)/delr
        
        do iter = 1, MAX_ITER

           p_want = model_mesa_hse(i+1,ipres) - &
                delr*((ONE-rfrac)*dens_zone + rfrac*model_mesa_hse(i+1,idens))*g_zone


           ! now we have two functions to zero:
           !   A = p_want - p(rho,T)
           !   B = entropy_want - s(rho,T)
           ! We use a two dimensional Taylor expansion and find the deltas
           ! for both density and temperature

           ! (t, rho) -> (p, s)

           eos_state%T     = temp_zone
           eos_state%rho   = dens_zone
           eos_state%xn(:) = xn(:)

           call eos(eos_input_rt, eos_state)

           entropy = eos_state%s
           pres_zone = eos_state%p

           dpt = eos_state%dpdt
           dpd = eos_state%dpdr
           dst = eos_state%dsdt
           dsd = eos_state%dsdr

           A = p_want - pres_zone
           B = entropy_want(i) - entropy

           dAdT = -dpt
           dAdrho = -(ONE-rfrac)*delr*g_zone - dpd
           dBdT = -dst
           dBdrho = -dsd

           dtemp = (B - (dBdrho/dAdrho)*A)/ &
                ((dBdrho/dAdrho)*dAdT - dBdT)

           drho = -(A + dAdT*dtemp)/dAdrho

           dens_zone = max(0.9_dp_t*dens_zone, &
                min(dens_zone + drho, 1.1_dp_t*dens_zone))

           temp_zone = max(0.9_dp_t*temp_zone, &
                min(temp_zone + dtemp, 1.1_dp_t*temp_zone))


           ! if (A < TOL .and. B < ETOL) then
           if (abs(drho) < TOL*dens_zone .and. abs(dtemp) < TOL*temp_zone) then
              converged_hse = .TRUE.
              exit
           endif

        enddo

        if (.NOT. converged_hse) then

           print *, 'Error zone', i, ' did not converge in init_1d'
           print *, 'integrate up'
           print *, dens_zone, temp_zone
           print *, p_want
           print *, drho
           call bl_error('Error: HSE non-convergence')

        endif

        ! call the EOS one more time for this zone and then go on to the next
        ! (t, rho) -> (p, s)

        eos_state%T     = temp_zone
        eos_state%rho   = dens_zone
        eos_state%xn(:) = xn(:)

        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        dpd = eos_state%dpdr

        ! update the thermodynamics in this zone
        model_mesa_hse(i,idens) = dens_zone
        model_mesa_hse(i,itemp) = temp_zone
        model_mesa_hse(i,ipres) = pres_zone
        model_mesa_hse(i,ientr) = eos_state%s
        ! model_mesa_hse(i,isndspd) = &
        !      sqrt(eos_state%gam1*eos_state%p/eos_state%rho)

     enddo

     if (abs(model_mesa_hse(1,idens) - central_density) < TOL*central_density) then
        converged_central_density = .true.
        exit
     endif

     central_density = model_mesa_hse(1,idens)

  enddo

  if (.NOT. converged_central_density) then
     print *, 'ERROR: central density iterations did not converge'
     call bl_error('ERROR: non-convergence')
  endif


  print *, 'converged central density = ', model_mesa_hse(1,idens)
  print *, ' '

  !===========================================================================
  ! compute the full HSE model using our new central density and temperature,
  ! and the temperature structure as dictated by the Mesa model.
  !===========================================================================

  print *, 'putting MESA model into HSE on our grid...'

  ! compute the enclosed mass
  delr = delrl(1) + delrr(1)
  M_enclosed(1) = FOUR3RD*M_PI*delr**3*model_mesa_hse(1,idens)

  fluff = .FALSE.

  do i = 2, nr

     ! use previous zone as initial guess for T, rho
     dens_zone = model_mesa_hse(i-1,idens)
     temp_zone = model_mesa_hse(i-1,itemp)

     xn(:) = model_mesa_hse(i,ispec:nvar)

     ! compute the gravitational acceleration on the interface between zones
     ! i-1 and i
     g_zone = -Gconst*M_enclosed(i-1)/(xznr(i-1)*xznr(i-1))


     !-----------------------------------------------------------------------
     ! iteration loop
     !-----------------------------------------------------------------------

     converged_hse = .FALSE.

     if (.not. fluff) then

        delr = delrl(i) + delrr(i-1)
        rfrac = delrr(i-1)/delr
        
        do iter = 1, MAX_ITER


           ! HSE differencing
           p_want = model_mesa_hse(i-1,ipres) + &
                delr*((ONE-rfrac)*dens_zone + rfrac*model_mesa_hse(i-1,idens))*g_zone

           temp_zone = model_mesa_hse(i,itemp)

           if (model_mesa_hse(i-1,idens) .lt. temp_fluff_cutoff) then
              temp_zone = temp_fluff
           end if

           ! (t, rho) -> (p)
           eos_state%T     = temp_zone
           eos_state%rho   = dens_zone
           eos_state%xn(:) = xn(:)

           call eos(eos_input_rt, eos_state)

           pres_zone = eos_state%p

           dpd = eos_state%dpdr
           drho = (p_want - pres_zone)/(dpd - (ONE-rfrac)*delr*g_zone)

           dens_zone = max(0.9_dp_t*dens_zone, &
                           min(dens_zone + drho, 1.1_dp_t*dens_zone))

           if (abs(drho) < TOL*dens_zone) then
              converged_hse = .TRUE.
              exit
           endif

           if (dens_zone < low_density_cutoff) then
              dens_zone = low_density_cutoff
              temp_zone = temp_fluff
              converged_hse = .TRUE.
              fluff = .TRUE.
              index_hse_fluff = i
              exit

           endif

        enddo

        if (.NOT. converged_hse) then

           print *, 'Error zone', i, ' did not converge in init_1d'
           print *, 'integrate up'
           print *, dens_zone, temp_zone
           print *, p_want
           print *, drho
           call bl_error('Error: HSE non-convergence')

        endif

        if (temp_zone < temp_fluff) then
           temp_zone = temp_fluff
        endif

     else
        dens_zone = low_density_cutoff
        temp_zone = temp_fluff
     endif



     ! call the EOS one more time for this zone and then go on to the next
     ! (t, rho) -> (p)

     eos_state%T     = temp_zone
     eos_state%rho   = dens_zone
     eos_state%xn(:) = xn(:)

     call eos(eos_input_rt, eos_state)

     pres_zone = eos_state%p


     ! update the thermodynamics in this zone
     model_mesa_hse(i,idens) = dens_zone
     model_mesa_hse(i,itemp) = temp_zone
     model_mesa_hse(i,ipres) = pres_zone
     model_mesa_hse(i,ientr) = eos_state%s
     ! model_mesa_hse(i,isndspd) = &
     !      sqrt(eos_state%gam1*eos_state%p/eos_state%rho)

     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_mesa_hse(i,idens)

  enddo


  !===========================================================================
  ! compute the alternate model using the same central density and
  ! temperature, but assuming that we are isentropic (and in HSE).
  !===========================================================================

!!$  print *, 'creating isentropic model...'
!!$
!!$  ! as an initial guess, use the Mesa HSE model
!!$  model_isentropic_hse(:,:) = model_mesa_hse(:,:)
!!$
!!$  entropy_want(:) = model_isentropic_hse(1,ientr)
!!$
!!$  fluff = .false.
!!$  isentropic = .true.
!!$
!!$  ! keep track of the mass enclosed below the current zone
!!$  delr = delrl(1) + delrr(1)
!!$  M_enclosed(1) = FOUR3RD*M_PI*delr**3*model_isentropic_hse(1,idens)
!!$
!!$  do i = 2, nr
!!$
!!$     ! use previous zone as initial guess for T, rho
!!$     dens_zone = model_isentropic_hse(i-1,idens)
!!$     temp_zone = model_isentropic_hse(i-1,itemp)
!!$
!!$     xn(:) = model_isentropic_hse(i,ispec:nvar)
!!$
!!$     g_zone = -Gconst*M_enclosed(i-1)/(xznr(i-1)*xznr(i-1))
!!$
!!$
!!$     !-----------------------------------------------------------------------
!!$     ! iteration loop
!!$     !-----------------------------------------------------------------------
!!$
!!$     ! start off the Newton loop by saying that the zone has not converged
!!$     converged_hse = .FALSE.
!!$
!!$     if (.not. fluff) then
!!$
!!$        delr = delrl(i) + delrr(i-1)
!!$        rfrac = delrr(i-1)/delr
!!$        
!!$        do iter = 1, MAX_ITER
!!$
!!$           if (isentropic) then
!!$
!!$              p_want = model_isentropic_hse(i-1,ipres) + &
!!$                   delr*((ONE-rfrac)*dens_zone + rfrac*model_isentropic_hse(i-1,idens))*g_zone
!!$
!!$
!!$              ! now we have two functions to zero:
!!$              !   A = p_want - p(rho,T)
!!$              !   B = entropy_want - s(rho,T)
!!$              ! We use a two dimensional Taylor expansion and find the deltas
!!$              ! for both density and temperature
!!$
!!$              ! (t, rho) -> (p, s)
!!$
!!$              eos_state%T     = temp_zone
!!$              eos_state%rho   = dens_zone
!!$              eos_state%xn(:) = xn(:)
!!$
!!$              call eos(eos_input_rt, eos_state)
!!$
!!$              entropy = eos_state%s
!!$              pres_zone = eos_state%p
!!$
!!$              dpt = eos_state%dpdt
!!$              dpd = eos_state%dpdr
!!$              dst = eos_state%dsdt
!!$              dsd = eos_state%dsdr
!!$
!!$              A = p_want - pres_zone
!!$              B = entropy_want(i) - entropy
!!$
!!$              dAdT = -dpt
!!$              dAdrho = (ONE-rfrac)*delr*g_zone - dpd
!!$              dBdT = -dst
!!$              dBdrho = -dsd
!!$
!!$              dtemp = (B - (dBdrho/dAdrho)*A)/ &
!!$                   ((dBdrho/dAdrho)*dAdT - dBdT)
!!$
!!$              drho = -(A + dAdT*dtemp)/dAdrho
!!$
!!$              dens_zone = max(0.9_dp_t*dens_zone, &
!!$                              min(dens_zone + drho, 1.1_dp_t*dens_zone))
!!$
!!$              temp_zone = max(0.9_dp_t*temp_zone, &
!!$                              min(temp_zone + dtemp, 1.1_dp_t*temp_zone))
!!$
!!$
!!$              if (dens_zone < low_density_cutoff) then
!!$
!!$                 dens_zone = low_density_cutoff
!!$                 temp_zone = temp_fluff
!!$                 converged_hse = .TRUE.
!!$                 fluff = .TRUE.
!!$                 exit
!!$
!!$              endif
!!$
!!$              ! if (A < TOL .and. B < ETOL) then
!!$              if (abs(drho) < TOL*dens_zone .and. abs(dtemp) < TOL*temp_zone) then
!!$                 converged_hse = .TRUE.
!!$                 exit
!!$              endif
!!$
!!$           else
!!$
!!$              ! do isothermal
!!$              p_want = model_isentropic_hse(i-1,ipres) + &
!!$                   delr*((ONE-rfrac)*dens_zone + rfrac*model_isentropic_hse(i-1,idens))*g_zone
!!$
!!$              temp_zone = temp_fluff
!!$
!!$              ! (t, rho) -> (p, s)
!!$
!!$              eos_state%T     = temp_zone
!!$              eos_state%rho   = dens_zone
!!$              eos_state%xn(:) = xn(:)
!!$
!!$              call eos(eos_input_rt, eos_state)
!!$
!!$              entropy = eos_state%s
!!$              pres_zone = eos_state%p
!!$
!!$              dpd = eos_state%dpdr
!!$
!!$              drho = (p_want - pres_zone)/(dpd - (ONE-rfrac)*delr*g_zone)
!!$
!!$              dens_zone = max(0.9*dens_zone, &
!!$                   min(dens_zone + drho, 1.1*dens_zone))
!!$
!!$              if (abs(drho) < TOL*dens_zone) then
!!$                 converged_hse = .TRUE.
!!$                 exit
!!$              endif
!!$
!!$              if (dens_zone < low_density_cutoff) then
!!$
!!$                 dens_zone = low_density_cutoff
!!$                 temp_zone = temp_fluff
!!$                 converged_hse = .TRUE.
!!$                 fluff = .TRUE.
!!$                 exit
!!$
!!$              endif
!!$
!!$           endif
!!$
!!$        enddo
!!$
!!$        if (.NOT. converged_hse) then
!!$
!!$           print *, 'Error zone', i, ' did not converge in init_1d'
!!$           print *, 'integrate up'
!!$           print *, dens_zone, temp_zone
!!$           print *, p_want
!!$           print *, drho
!!$           call bl_error('Error: HSE non-convergence')
!!$
!!$        endif
!!$
!!$        if (temp_zone < temp_fluff) then
!!$           temp_zone = temp_fluff
!!$           isentropic = .false.
!!$        endif
!!$
!!$     else
!!$        dens_zone = low_density_cutoff
!!$        temp_zone = temp_fluff
!!$     endif
!!$
!!$
!!$     ! call the EOS one more time for this zone and then go on to the next
!!$     ! (t, rho) -> (p, s)
!!$
!!$     eos_state%T     = temp_zone
!!$     eos_state%rho   = dens_zone
!!$     eos_state%xn(:) = xn(:)
!!$
!!$     call eos(eos_input_rt, eos_state)
!!$
!!$     pres_zone = eos_state%p
!!$
!!$     dpd = eos_state%dpdr
!!$
!!$     ! update the thermodynamics in this zone
!!$     model_isentropic_hse(i,idens) = dens_zone
!!$     model_isentropic_hse(i,itemp) = temp_zone
!!$     model_isentropic_hse(i,ipres) = pres_zone
!!$     model_isentropic_hse(i,ientr) = eos_state%s
!!$     model_isentropic_hse(i,isndspd) = &
!!$          sqrt(eos_state%gam1*eos_state%p/eos_state%rho)
!!$
!!$     M_enclosed(i) = M_enclosed(i-1) + &
!!$          FOUR3RD*M_PI*(xznr(i) - xznl(i))* &
!!$          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_isentropic_hse(i,idens)
!!$
!!$  enddo


  !===========================================================================
  ! compute a hybrid model -- isentropic in the interior, Mesa's temperature
  ! structure outside.
  !===========================================================================

!!$  print *, 'creating hybrid model...'
!!$  print *, ' '
!!$  eint_hybrid = 0.0
!!$
!!$
!!$  max_temp = maxval(model_mesa_hse(:,itemp))
!!$  i_isentropic = -1
!!$  do i = 1, nr
!!$     model_hybrid_hse(i,:) = model_isentropic_hse(i,:)
!!$
!!$     if (model_mesa_hse(i,itemp) > model_isentropic_hse(i,itemp)) then
!!$
!!$        ! there will be a few regions in the very, very center where
!!$        ! the mesa temperature may be slightly higher than the
!!$        ! isentropic, but we are still not done with isentropic.
!!$        ! i_isentropic is an index that keeps track of when we switch
!!$        ! to the original mesa model "for real".  This is used for
!!$        ! diagnostics.  We require the temperature to have dropped by
!!$        ! 10% from the central value at least...
!!$        if (i_isentropic == -1 .and. &
!!$             model_isentropic_hse(i,itemp) < 0.9*max_temp) i_isentropic = i
!!$
!!$        model_hybrid_hse(i,itemp) = model_mesa_hse(i,itemp)
!!$     endif
!!$
!!$  enddo
!!$
!!$  ! the outer part of the star will be using the original mesa
!!$  ! temperature structure.  Because the hybrid model might hit the
!!$  ! fluff region earlier or later than the mesa model, reset the
!!$  ! temperatures in the fluff region to the last valid mesa zone.
!!$  model_hybrid_hse(index_hse_fluff:,itemp) = model_mesa_hse(index_hse_fluff-1,itemp)
!!$
!!$
!!$  ! compute the enclosed mass
!!$  delr = delrl(1) + delrr(1)
!!$  M_enclosed(1) = FOUR3RD*M_PI*delr**3*model_hybrid_hse(1,idens)
!!$
!!$  fluff = .FALSE.
!!$
!!$  do i = 2, nr
!!$
!!$     ! use previous zone as initial guess for T, rho
!!$     dens_zone = model_hybrid_hse(i-1,idens)
!!$     temp_zone = model_hybrid_hse(i-1,itemp)
!!$
!!$     xn(:) = model_hybrid_hse(i,ispec:nvar)
!!$
!!$     ! compute the gravitational acceleration on the interface between zones
!!$     ! i-1 and i
!!$     g_zone = -Gconst*M_enclosed(i-1)/(xznr(i-1)*xznr(i-1))
!!$
!!$
!!$     !-----------------------------------------------------------------------
!!$     ! iteration loop
!!$     !-----------------------------------------------------------------------
!!$
!!$     converged_hse = .FALSE.
!!$
!!$     if (.not. fluff) then
!!$
!!$        delr = delrl(i) + delrr(i-1)
!!$        rfrac = delrr(i-1)/delr
!!$        
!!$        do iter = 1, MAX_ITER
!!$
!!$
!!$           ! HSE differencing
!!$           p_want = model_hybrid_hse(i-1,ipres) + &
!!$                delr*((ONE-rfrac)*dens_zone + rfrac*model_hybrid_hse(i-1,idens))*g_zone
!!$
!!$           temp_zone = model_hybrid_hse(i,itemp)
!!$
!!$           ! (t, rho) -> (p)
!!$           eos_state%T     = temp_zone
!!$           eos_state%rho   = dens_zone
!!$           eos_state%xn(:) = xn(:)
!!$
!!$           call eos(eos_input_rt, eos_state)
!!$
!!$           pres_zone = eos_state%p
!!$
!!$           dpd = eos_state%dpdr
!!$           drho = (p_want - pres_zone)/(dpd - (ONE-rfrac)*delr*g_zone)
!!$
!!$           dens_zone = max(0.9_dp_t*dens_zone, &
!!$                           min(dens_zone + drho, 1.1_dp_t*dens_zone))
!!$
!!$           if (abs(drho) < TOL*dens_zone) then
!!$              converged_hse = .TRUE.
!!$              exit
!!$           endif
!!$
!!$           if (dens_zone <= low_density_cutoff) then
!!$              dens_zone = low_density_cutoff
!!$              temp_zone = temp_fluff
!!$              converged_hse = .TRUE.
!!$              fluff = .TRUE.
!!$              exit
!!$
!!$           endif
!!$
!!$        enddo
!!$
!!$        if (.NOT. converged_hse) then
!!$
!!$           print *, 'Error zone', i, ' did not converge in init_1d'
!!$           print *, 'integrate up'
!!$           print *, dens_zone, temp_zone
!!$           print *, p_want
!!$           print *, drho
!!$           call bl_error('Error: HSE non-convergence')
!!$
!!$        endif
!!$
!!$        if (temp_zone < temp_fluff) then
!!$           temp_zone = temp_fluff
!!$        endif
!!$
!!$     else
!!$        dens_zone = low_density_cutoff
!!$        temp_zone = temp_fluff
!!$     endif
!!$
!!$
!!$
!!$     ! call the EOS one more time for this zone and then go on to the next
!!$     ! (t, rho) -> (p)
!!$
!!$     eos_state%T     = temp_zone
!!$     eos_state%rho   = dens_zone
!!$     eos_state%xn(:) = xn(:)
!!$
!!$     call eos(eos_input_rt, eos_state)
!!$
!!$     pres_zone = eos_state%p
!!$
!!$
!!$     ! update the thermodynamics in this zone
!!$     model_hybrid_hse(i,idens) = dens_zone
!!$     model_hybrid_hse(i,itemp) = temp_zone
!!$     model_hybrid_hse(i,ipres) = pres_zone
!!$     model_hybrid_hse(i,ientr) = eos_state%s
!!$     model_hybrid_hse(i,isndspd) = &
!!$          sqrt(eos_state%gam1*eos_state%p/eos_state%rho)
!!$
!!$     eint_hybrid = eint_hybrid + &
!!$          dens_zone*eos_state%e*FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
!!$          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)
!!$
!!$     M_enclosed(i) = M_enclosed(i-1) + &
!!$          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
!!$          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_hybrid_hse(i,idens)
!!$
!!$  enddo




  !===========================================================================
  ! output
  !===========================================================================

  !---------------------------------------------------------------------------
  ! MESA model
  !---------------------------------------------------------------------------

  model_name = 'hse'
  
  call write_model(model_name, model_mesa_hse)

  ! compute the enclosed mass
  delr = delrl(1) + delrr(1)
  M_enclosed(1) = FOUR3RD*M_PI*delr**3*model_mesa_hse(1,idens)

  do i = 2, nr
     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_mesa_hse(i,idens)
  enddo

  print *, 'total mass = ', real(M_enclosed(nr)), ' g = ', real(M_enclosed(nr)/M_solar), ' solar masses'


  ! compute the maximum HSE error
  max_hse_error = -1.d30

  do i = 2, nr-1
     g_zone = -Gconst*M_enclosed(i-1)/xznr(i-1)**2
     
     delr = delrl(i) + delrr(i-1)
     dpdr = (model_mesa_hse(i,ipres) - model_mesa_hse(i-1,ipres))/delr
     
     rfrac = delrr(i-1)/delr
     rhog = ((1.0_dp_t-rfrac)*model_mesa_hse(i,idens) + rfrac*model_mesa_hse(i-1,idens))*g_zone

     if (dpdr /= ZERO .and. model_mesa_hse(i+1,idens) > low_density_cutoff) then
        max_hse_error = max(max_hse_error, abs(dpdr - rhog)/abs(dpdr))
     endif
  enddo

  print *, 'maximum HSE error = ', max_hse_error
  print *, ' '

  !---------------------------------------------------------------------------
  ! isentropic model
  !---------------------------------------------------------------------------

!!$  ipos = index(model_file, '.raw')
!!$  outfile = model_file(1:ipos-1) // '.isentropic.hse'
!!$
!!$  write(num,'(i8)') nr
!!$
!!$  outfile = trim(outfile) // '.' // trim(adjustl(num))
!!$
!!$  print *, 'writing HSE isentropic model to ', trim(outfile)
!!$
!!$  open (unit=50, file=outfile, status="unknown")
!!$
!!$  write (50,1001) "# npts = ", nr
!!$  write (50,1001) "# num of variables = ", 3 + nspec
!!$  write (50,1002) "# density"
!!$  write (50,1002) "# temperature"
!!$  write (50,1002) "# pressure"
!!$
!!$  do n = 1, nspec
!!$     write (50,1003) "# ", spec_names(n)
!!$  enddo
!!$
!!$  do i = 1, nr
!!$
!!$     write (50,1000) xzn_hse(i), model_isentropic_hse(i,idens), model_isentropic_hse(i,itemp), model_isentropic_hse(i,ipres), &
!!$          (model_isentropic_hse(i,ispec-1+n), n=1,nspec)
!!$
!!$  enddo
!!$
!!$  close (unit=50)
!!$
!!$
!!$  ! compute the enclosed mass
!!$  delr = delrl(1) + delrr(1)
!!$  M_enclosed(1) = FOUR3RD*M_PI*delr**3*model_isentropic_hse(1,idens)
!!$
!!$  do i = 2, nr
!!$     M_enclosed(i) = M_enclosed(i-1) + &
!!$          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
!!$          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_isentropic_hse(i,idens)
!!$  enddo
!!$
!!$  print *, 'total mass = ', real(M_enclosed(nr)), ' g = ', real(M_enclosed(nr)/M_solar), ' solar masses'
!!$
!!$
!!$  ! compute the maximum HSE error
!!$  max_hse_error = -1.d30
!!$
!!$  do i = 2, nr-1
!!$     g_zone = -Gconst*M_enclosed(i-1)/xznr(i-1)**2
!!$     
!!$     delr = delrl(i) + delrr(i-1)
!!$     dpdr = (model_isentropic_hse(i,ipres) - model_isentropic_hse(i-1,ipres))/delr
!!$     
!!$     rfrac = delrr(i-1)/delr
!!$     rhog = ((1.0_dp_t-rfrac)*model_isentropic_hse(i,idens) + rfrac*model_isentropic_hse(i-1,idens))*g_zone
!!$
!!$     if (dpdr /= ZERO .and. model_isentropic_hse(i+1,idens) > low_density_cutoff) then
!!$        max_hse_error = max(max_hse_error, abs(dpdr - rhog)/abs(dpdr))
!!$     endif
!!$  enddo
!!$
!!$  print *, 'maximum HSE error = ', max_hse_error
!!$  print *, ' '


  !---------------------------------------------------------------------------
  ! hybrid model
  !---------------------------------------------------------------------------
!!$
!!$  ipos = index(model_file, '.raw')
!!$  outfile = model_file(1:ipos-1) // '.hybrid.hse'
!!$
!!$  write(num,'(i8)') nr
!!$
!!$  outfile = trim(outfile) // '.' // trim(adjustl(num))
!!$
!!$  print *, 'writing HSE hybrid model to ', trim(outfile)
!!$
!!$  open (unit=50, file=outfile, status="unknown")
!!$
!!$  write (50,1001) "# npts = ", nr
!!$  write (50,1001) "# num of variables = ", 3 + nspec
!!$  write (50,1002) "# density"
!!$  write (50,1002) "# temperature"
!!$  write (50,1002) "# pressure"
!!$
!!$  do n = 1, nspec
!!$     write (50,1003) "# ", spec_names(n)
!!$  enddo
!!$
!!$  do i = 1, nr
!!$
!!$     write (50,1000) xzn_hse(i), model_hybrid_hse(i,idens), model_hybrid_hse(i,itemp), model_hybrid_hse(i,ipres), &
!!$          (model_hybrid_hse(i,ispec-1+n), n=1,nspec)
!!$
!!$  enddo
!!$
!!$  close (unit=50)
!!$
!!$
!!$  ! compute the enclosed mass
!!$  delr = delrl(1) + delrr(1)
!!$  M_enclosed(1) = FOUR3RD*M_PI*delr**3*model_hybrid_hse(1,idens)
!!$
!!$  do i = 2, nr
!!$     M_enclosed(i) = M_enclosed(i-1) + &
!!$          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
!!$          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_hybrid_hse(i,idens)
!!$  enddo
!!$
!!$  print *, 'total mass = ', real(M_enclosed(nr)), ' g = ', real(M_enclosed(nr)/M_solar), ' solar masses'
!!$  print *, 'mass of convective region = ', real(M_enclosed(i_isentropic)), ' g = ', &
!!$       real(M_enclosed(i_isentropic)/M_solar), ' solar masses'
!!$  print *, 'radius of convective region = ', real(xzn_hse(i_isentropic)), ' cm'
!!$
!!$  ! compute the maximum HSE error
!!$  max_hse_error = -1.d30
!!$
!!$  do i = 2, nr-1
!!$     g_zone = -Gconst*M_enclosed(i-1)/xznr(i-1)**2
!!$     
!!$     delr = delrl(i) + delrr(i-1)
!!$     dpdr = (model_hybrid_hse(i,ipres) - model_hybrid_hse(i-1,ipres))/delr
!!$     
!!$     rfrac = delrr(i-1)/delr
!!$     rhog = ((1.0_dp_t-rfrac)*model_hybrid_hse(i,idens) + rfrac*model_hybrid_hse(i-1,idens))*g_zone
!!$
!!$     if (dpdr /= ZERO .and. model_hybrid_hse(i+1,idens) > low_density_cutoff) then
!!$        max_hse_error = max(max_hse_error, abs(dpdr - rhog)/abs(dpdr))
!!$     endif
!!$  enddo
!!$
!!$  print *, 'maximum HSE error = ', max_hse_error
!!$
!!$
!!$
!!$  ! output the entropy
!!$
!!$  outfile = model_file(1:ipos-1) // '.entropy'
!!$  outfile = trim(outfile) // '.' // trim(adjustl(num))
!!$
!!$  open (unit=60, file=outfile, status="unknown")
!!$
!!$  do i = 1, nr
!!$     write (60,1000) xzn_hse(i), model_mesa_hse(i,ientr)
!!$  enddo
!!$
!!$  close (unit=60)
!!$
!!$
!!$  ! compute the mass enclosed inside the anelastic_cutoff
!!$  delr = delrl(1) + delrr(1)
!!$  M_enclosed_anel = FOUR3RD*M_PI*delr**3*model_hybrid_hse(1,idens)
!!$  do i = 2, nr
!!$     if (model_hybrid_hse(i,idens) >= anelastic_cutoff) then
!!$        M_enclosed_anel = M_enclosed_anel + &
!!$             FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
!!$             (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_hybrid_hse(i,idens)
!!$     else
!!$        exit
!!$     endif
!!$  enddo
!!$
!!$  print *, ' '
!!$  print *, 'mass within anelastic_cutoff (', real(anelastic_cutoff), ') =', &
!!$       real(M_enclosed_anel/M_solar), 'solar masses'
!!$
!!$
!!$  ! compute the central sound speed
!!$  print *, 'sound speed at center of star = ', model_hybrid_hse(1,isndspd)
!!$
!!$
!!$  ! compute the gravitational potential energy
!!$  M_center = FOUR3RD*M_PI*xzn_hse(1)**3*model_hybrid_hse(1,idens)
!!$
!!$  ! dU = - G M dM / r;  dM = 4 pi r**2 rho dr  -->  dU = - 4 pi G r rho dr
!!$  grav_ener = -FOUR*M_PI*Gconst*M_center*xzn_hse(1)*model_hybrid_hse(1,idens)*(xznr(1) - xznl(1))
!!$
!!$
!!$  do i = 2, nr
!!$     if (model_hybrid_hse(i,idens) >= anelastic_cutoff) then
!!$        M_center = M_center + &
!!$             FOUR3RD*M_PI*(xzn_hse(i) - xznl(i)) * &
!!$             (xzn_hse(i)**2 +xznl(i)*xzn_hse(i) + xznl(i)**2)*model_hybrid_hse(i,idens) + &
!!$             FOUR3RD*M_PI*(xznr(i-1) - xzn_hse(i-1)) * &
!!$             (xznr(i-1)**2 +xzn_hse(i-1)*xznr(i-1) + xzn_hse(i-1)**2)*model_hybrid_hse(i-1,idens)
!!$
!!$        ! dU = - G M dM / r;  dM = 4 pi r**2 rho dr  -->  dU = - 4 pi G r rho dr
!!$        grav_ener = grav_ener - &
!!$             FOUR*M_PI*Gconst*M_center*xzn_hse(i)*model_hybrid_hse(i,idens)*(xznr(i) - xznl(i))
!!$     else
!!$        exit
!!$     endif
!!$  enddo
!!$
!!$  print *, "gravitational potential energy = ", grav_ener
!!$  print *, "internal energy = ", eint_hybrid

contains


  function interpolate(r, npts, model_r, model_var)

    use bl_types

    implicit none


    ! given the array of model coordinates (model_r), and variable (model_var),
    ! find the value of model_var at point r using linear interpolation.
    ! Eventually, we can do something fancier here.

    real(kind=dp_t) :: interpolate
    real(kind=dp_t), intent(in) :: r
    integer :: npts
    real(kind=dp_t), dimension(npts) :: model_r, model_var

    real(kind=dp_t) :: slope
    real(kind=dp_t) :: minvar, maxvar

    integer :: i, id

    ! find the location in the coordinate array where we want to interpolate
    do i = 1, npts
       if (model_r(i) >= r) exit
    enddo

    id = i

    if (id == 1) then

       slope = (model_var(id+1) - model_var(id))/(model_r(id+1) - model_r(id))
       interpolate = slope*(r - model_r(id)) + model_var(id)

       ! safety check to make sure interpolate lies within the bounding points
       !minvar = min(model_var(id+1),model_var(id))
       !maxvar = max(model_var(id+1),model_var(id))
       !interpolate = max(interpolate,minvar)
       !interpolate = min(interpolate,maxvar)

    else

       slope = (model_var(id) - model_var(id-1))/(model_r(id) - model_r(id-1))
       interpolate = slope*(r - model_r(id)) + model_var(id)

       ! safety check to make sure interpolate lies within the bounding points
       minvar = min(model_var(id),model_var(id-1))
       maxvar = max(model_var(id),model_var(id-1))
       interpolate = max(interpolate,minvar)
       interpolate = min(interpolate,maxvar)

    endif

    return

  end function interpolate


  subroutine write_model(model_name, model_state)

    !! Write data stored in `model_state` array to file

    use model_params

    implicit none

    character (len=100), intent(in) :: model_name
    ! integer, intent(in) :: nx, nvar
    real(kind=dp_t), intent(in) :: model_state(nr, nvar)

    character(len=100) :: outfile
    integer :: ipos
    
    character (len=8) :: num
    integer :: i,n

1000 format (1x, 30(g26.16, 1x))
1001 format(a, i5)
1002 format(a)
1003 format(a,a)

    ipos = index(model_file, '.dat')
    if (ipos .eq. 0) then 
        ipos = index(model_file, '.txt')
    endif
    outfile = model_file(1:ipos-1) // '.' // trim(adjustl(model_name))

    write(num,'(i8)') nr

    outfile = trim(outfile) // '.' // trim(adjustl(num))

    print *, 'writing ', trim(adjustl(model_name)), ' model to ', trim(outfile)

    open (unit=50, file=outfile, status="unknown")

    write (50,1001) "# npts = ", nr
    write (50,1001) "# num of variables = ", 3 + nspec
    write (50,1002) "# density"
    write (50,1002) "# temperature"
    write (50,1002) "# pressure"
    ! write (50,1002) "# conv_vel"

    do n = 1, nspec
       write (50,1003) "# ", spec_names(n)
    enddo

    do i = 1, nr

        if (mesa) then

            ! write (50,1000) xzn_hse(i), model_state(i,idens), model_state(i,itemp), &
            !         model_state(i,ipres), model_state(i,iconv_vel), &
            !         (model_state(i,ispec-1+n), n=1,nspec)

        else

            write (50,1000) xzn_hse(i), model_state(i,idens), model_state(i,itemp), &
                 model_state(i,ipres), &
                 (model_state(i,ispec-1+n), n=1,nspec)
     

        endif

    enddo

    close (unit=50)


  end subroutine write_model

  subroutine read_file(filename, base_state, base_r, var_names_model, nvars_model, npts_file) 

    use bl_types
    use amrex_constants_module
    use amrex_error_module
    use network
    use fundamental_constants_module

    implicit none

    integer, parameter :: MAX_VARNAME_LENGTH=80

    character (len=100), intent(in) :: filename
    real(kind=dp_t), allocatable, intent(inout) :: base_state(:,:)
    real(kind=dp_t), allocatable, intent(inout) :: base_r(:)
    character (len=MAX_VARNAME_LENGTH), intent(in) :: var_names_model(:)
    integer, intent(in) :: nvars_model
    integer, intent(out) :: npts_file

    integer :: nparams_file, nvars_file, status, ipos
    character (len=5000) :: header_line
    real(kind=dp_t), allocatable :: vars_stored(:), params_stored(:)
    character(len=MAX_VARNAME_LENGTH), allocatable :: paramnames_stored(:)
    character(len=MAX_VARNAME_LENGTH), allocatable :: var_names_file(:)
    integer, allocatable :: var_indices_file(:)
    logical :: found
    integer :: i, j, k, n

1000 format (1x, 30(g26.16, 1x))

    open(99,file=filename)

    ! going to first do a pass through the file to count the line numbers
    npts_file = 0
    do
        read (99,*,iostat=status)
        if (status > 0) then
            write(*,*) "Something went wrong :("
        else if (status < 0) then
            exit
        else
            npts_file = npts_file + 1
        endif
    enddo

    rewind(99)

     ! the second line gives the number of variables
    read(99, *)
    read(99, '(a2000)') header_line
    ! find last space in line
    ipos = index(trim(header_line), ' ', back=.true.)
    header_line = trim(adjustl(header_line(ipos:)))
    read (header_line, *) nvars_file

    print *, nvars_file, ' variables found in the initial model file'

    allocate (vars_stored(0:nvars_file))
    allocate (var_names_file(nvars_file))
    allocate (var_indices_file(nvars_file))

    ! subtract header rows 
    npts_file = npts_file - nvars_file - 2

    print *, npts_file, '    points found in the initial model file'

    var_indices_file(:) = -1

    ! now read in the names of the variables
    ipos = 1
    do i = 1, nvars_file
       read (99, '(a5000)') header_line
    !    header_line = trim(adjustl(header_line(ipos:)))
    !    ipos = index(header_line, ' ') + 1
       var_names_file(i) = trim(adjustl(header_line))

       ! create map of file indices to model indices
       do j = 1, nvars_model
          if (var_names_file(i) == var_names_model(j)) then
             var_indices_file(i) = j
             exit
          endif
       enddo

       ! map species as well
       if (var_indices_file(i) == -1) then
          k = network_species_index(var_names_file(i))
          if (k > 0) then
             var_indices_file(i) = nvars_model + k
          endif
       endif
    enddo

    ! allocate storage for the model data
    allocate (base_state(npts_file, nvars_model+nspec))
    allocate (base_r(npts_file))

    do i = 1, npts_file
       read(99, *) (vars_stored(j), j = 0, nvars_file)

       base_state(i,:) = ZERO

       base_r(i) = vars_stored(0)

       do j = 1, nvars_file
          if (var_indices_file(j) .ge. 0) then
             base_state(i, var_indices_file(j)) = vars_stored(j)
          endif

       enddo

    enddo

  end subroutine read_file

end program init_1d_irreg
