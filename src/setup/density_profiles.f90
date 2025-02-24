!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2022 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://phantomsph.bitbucket.io/                                          !
!--------------------------------------------------------------------------!
module rho_profile
!
! This contains several density profiles, including
!               1) uniform
!               2) polytrope
!               3) piecewise polytrope
!               4) Evrard
!               5) Read data from MESA file
!               6) Read data from KEPLER file
!               7) Bonnor-Ebert sphere
!
! :References: None
!
! :Owner: Daniel Price
!
! :Runtime parameters: None
!
! :Dependencies: datafiles, eos, fileutils, physcon, prompting, units
!
 use physcon, only:pi,fourpi
 implicit none

 public  :: rho_uniform,rho_polytrope,rho_piecewise_polytrope, &
            rho_evrard,read_mesa,read_kepler_file, &
            rho_bonnorebert,prompt_BEparameters
 public  :: write_profile,calc_mass_enc
 private :: integrate_rho_profile

 abstract interface
  real function func(x)
   real, intent(in) :: x
  end function func
 end interface

contains

!-----------------------------------------------------------------------
!+
!  Option 1:
!  Uniform density sphere
!+
!-----------------------------------------------------------------------
subroutine rho_uniform(ng,mass,radius,rtab,rhotab)
 integer, intent(in)  :: ng
 real,    intent(in)  :: mass,radius
 real,    intent(out) :: rtab(:),rhotab(:)
 integer              :: i
 real                 :: dr,density

 density = 3.0*mass/(fourpi*radius**3)
 dr      = radius/real(ng)
 do i=1,ng
    rtab(i)   = i*dr
    rhotab(i) = density
 enddo

end subroutine rho_uniform

!-----------------------------------------------------------------------
!+
!  Option 2:
!  Density profile for a polytrope (assumes G==1)
!+
!-----------------------------------------------------------------------
subroutine rho_polytrope(gamma,polyk,Mstar,rtab,rhotab,npts,rhocentre,set_polyk,Rstar)
 integer, intent(out)             :: npts
 real,    intent(in)              :: gamma
 real,    intent(in)              :: Mstar
 real,    intent(inout)           :: rtab(:),polyk
 real,    intent(out)             :: rhotab(size(rtab))
 real,    intent(inout), optional :: Rstar
 real,    intent(out),   optional :: rhocentre
 logical, intent(in),    optional :: set_polyk
 integer                          :: i,j
 real                             :: r(size(rtab)),v(size(rtab)),den(size(rtab))
 real                             :: dr,an,rhs,Mstar_f,rhocentre0
 real                             :: fac,rfac

 dr   = 0.001
 an   = 1./(gamma-1.)
 v(1) = 0.0
 v(2) = dr*(1.0 - dr*dr/6. )
 r(1) = 0.

 i = 2
 do while (v(i) >= 0.)
    r(i)    = (i-1)*dr
    rhs    = - r(i)*(v(i)/r(i))**an
    v(i+1) = 2*v(i) - v(i-1) + dr*dr*rhs
    i      = i + 1
    if (i+1 > size(rtab)) then ! array is not large enough; restart with larger dr
       dr   = dr*2.
       r(2) = dr
       v(2) = dr*(1.0 - dr*dr/6. )
       i = 2
    endif
 enddo
 npts = i-1
 !
 !--Calculate the mass, Mstar_f, out to radius r using the density without
 !  the central density multiplier.
 !
 den(1) = 1.0
 Mstar_f = 0.
 do j = 2,npts
    den(j)   = (v(j)/r(j))**an
    Mstar_f  = Mstar_f + fourpi*r(j)*r(j)*den(j)*dr
 enddo
 !
 !--Rescale the central density to give desired mass, Mstar
 !  This is using the incorrect polyk
 !
 fac        = (gamma*polyk)/(fourpi*(gamma - 1.))
 rhocentre0 = ((Mstar/Mstar_f)/fac**1.5)**(2./(3.*gamma - 4.))
 rfac       = sqrt(fac*rhocentre0**(gamma - 2.))

 if (present(set_polyk) .and. present(Rstar) ) then
    if ( set_polyk ) then
       !--Rescale radius to get polyk
       rfac      = Rstar/(r(npts)*rfac)
       polyk     = polyk*rfac
       !
       !--Re-rescale central density to give desired mass (using the correct polyk)
       fac        = (gamma*polyk)/(fourpi*(gamma - 1.))
       rhocentre0 = ((Mstar/Mstar_f)/fac**1.5)**(2./(3.*gamma - 4.))
       rfac       = sqrt(fac*rhocentre0**(gamma - 2.))
    endif
 endif

 rtab   = r * rfac
 rhotab = rhocentre0 * den
 if (present(Rstar))     Rstar     = r(npts)*rfac
 if (present(rhocentre)) rhocentre = rhocentre0

end subroutine rho_polytrope

!-----------------------------------------------------------------------
!+
!  Option 3:
!  Calculate the density profile for a piecewise polytrope
!  Original Authors: Madeline Marshall & Bernard Field
!  Supervisors: James Wurster & Paul Lasky
!+
!-----------------------------------------------------------------------
subroutine rho_piecewise_polytrope(rtab,rhotab,rhocentre,mstar_in,get_dPdrho,npts,ierr)
 integer, intent(out)   :: npts,ierr
 real,    intent(in)    :: mstar_in
 real,    intent(out)   :: rhocentre,rtab(:),rhotab(:)
 integer, parameter     :: itermax = 1000
 integer                :: iter,lastsign
 real                   :: dr,drho,mstar
 logical                :: iterate,bisect
 procedure(func), pointer :: get_dPdrho
 !
 !--initialise variables
 iter      = 0
 ierr      = 0
 drho      = 0.0
 dr        = 30.0/size(rtab)
 rhocentre = 1.0
 lastsign  = 1
 iterate   = .true.
 bisect    = .false.
 !
 !--Iterate to get the correct density profile
 do while ( iterate )
    call integrate_rho_profile(rtab,rhotab,rhocentre,get_dPdrho,dr,npts,ierr)
    if (ierr > 0) then
       !--did not complete the profile; reset dr
       dr   = 2.0*dr
       ierr = 0
    else
       call calc_mass_enc(npts,rtab,rhotab,mstar=mstar)
       !--iterate to get the correct mass
       if (iter==0) then
          rhocentre = rhocentre * (mstar_in/mstar)**(1./3.)
          lastsign  = int( sign(1.0,mstar_in-mstar) )
       elseif (iter==1) then
          drho      = 0.1*rhocentre*lastsign
          lastsign  = int( sign(1.0,mstar_in-mstar) )
       else
          if (bisect) then
             drho = 0.5*drho*lastsign*sign(1.0,mstar_in-mstar)
          else
             if (lastsign /= int( sign(1.0,mstar_in-mstar) ) ) then
                bisect = .true.
                drho   = -0.5*drho
             endif
          endif
       endif
       rhocentre = rhocentre + drho
       lastsign  = int( sign(1.0,mstar_in-mstar) )
       iter      = iter + 1
       !--Converged: exit
       if (abs(mstar_in-mstar) < epsilon(mstar_in)*1.0d4) iterate = .false.
       !--Did not converge: abort
       if (iter > itermax) then
          ierr    = 2
          iterate = .false.
       endif
    endif
 enddo

end subroutine rho_piecewise_polytrope
!-----------------------------------------------------------------------
!  Calculate the density profile using an arbitrary EOS and
!  given a central density
!-----------------------------------------------------------------------
subroutine integrate_rho_profile(rtab,rhotab,rhocentre,get_dPdrho,dr,npts,ierr)
 integer, intent(out) :: npts,ierr
 real,    intent(out) :: rtab(:),rhotab(:)
 real,    intent(in)  :: rhocentre,dr
 integer              :: i
 real                 :: drhodr,dPdrho,dPdrho_prev
 logical              :: iterate
 procedure(func), pointer :: get_dPdrho

 !
 !--Initialise variables
 !
 i         = 1
 ierr      = 0
 rtab      = 0.0
 rhotab    = 0.0
 drhodr    = 0.0
 rtab(1)   = 0.0
 rhotab(1) = rhocentre
 iterate   = .true.
 dPdrho_prev = 0.0
 !
 do while ( iterate )
    i = i + 1
    rhotab(i) = rhotab(i-1) + dr*drhodr
    rtab(i)   = rtab(i-1)   + dr
    dPdrho    = get_dPdrho(rhotab(i))
    if (i==2) then
       drhodr = drhodr - fourpi*rhotab(i-1)**2*dr/dPdrho
    else
       drhodr = drhodr + dr*(drhodr**2/rhotab(i-1) &
              - fourpi*rhotab(i)**2/dPdrho &
              - (dPdrho-dPdrho_prev)/(dr*dPdrho)*drhodr - 2.0*drhodr/rtab(i) )
    endif
    dPdrho_prev = dPdrho
    if (rhotab(i) < 0.0) iterate = .false.
    if (i >=size(rtab)) then
       ierr    = 1
       iterate = .false.
    endif
 enddo

 npts         = i
 rhotab(npts) = 0.0

end subroutine integrate_rho_profile

!-----------------------------------------------------------------------
!  Calculate the enclosed mass of a star
!-----------------------------------------------------------------------
subroutine calc_mass_enc(npts,rtab,rhotab,mtab,mstar)
 integer, intent(in)            :: npts
 real,    intent(in)            :: rtab(:),rhotab(:)
 real,    intent(out), optional :: mtab(:),mstar
 integer                        :: i
 real                           :: ri,ro,menc(npts)

 ro      = 0.5*( rtab(1) + rtab(2) )
 menc(1) = ro**3*rhotab(1)/3.0
 do i = 2,npts-1
    ri      = 0.5*(rtab(i) + rtab(i-1))
    ro      = 0.5*(rtab(i) + rtab(i+1))
    menc(i) = menc(i-1) + rhotab(i)*rtab(i)**2*(ro - ri)
 enddo
 ri         = 0.5*(rtab(npts) + rtab(npts-1))
 menc(npts) = menc(npts-1) + rhotab(npts)*rtab(npts)**2*(rtab(npts) - ri)
 menc       = menc*fourpi

 if (present(mtab))  mtab  = menc
 if (present(mstar)) mstar = menc(npts)

end subroutine calc_mass_enc

!-----------------------------------------------------------------------
!+
!  Option 4:
!  Calculate the density profile for the Evrard Collapse
!+
!-----------------------------------------------------------------------
subroutine rho_evrard(ng,mass,radius,rtab,rhotab)
 integer, intent(in)  :: ng
 real,    intent(in)  :: mass,radius
 real,    intent(out) :: rtab(:),rhotab(:)
 integer              :: i
 real                 :: dr

 dr = radius/real(ng)
 do i=1,ng
    rtab(i)   = i*dr
    rhotab(i) = mass/(2.0*pi*radius*radius*rtab(i))
 enddo

end subroutine rho_evrard

!-----------------------------------------------------------------------
!+
!  Read quantities from MESA profile or from profile in the format of
!  the P12 star (phantom/data/star_data_files/P12_Phantom_Profile.data)
!+
!-----------------------------------------------------------------------
subroutine read_mesa(filepath,rho,r,pres,m,ene,temp,Xfrac,Yfrac,Mstar,ierr,cgsunits)
 use physcon,   only:solarm
 use eos,       only:X_in,Z_in
 use fileutils, only:get_nlines,get_ncolumns,string_delete,lcase
 use datafiles, only:find_phantom_datafile
 use units,     only:udist,umass,unit_density,unit_pressure,unit_ergg
 integer                                    :: lines,rows,i,ncols,nheaderlines
 character(len=*), intent(in)               :: filepath
 logical, intent(in), optional              :: cgsunits
 integer, intent(out)                       :: ierr
 character(len=10000)                       :: dumc
 character(len=120)                         :: fullfilepath
 character(len=24),allocatable              :: header(:),dum(:)
 logical                                    :: iexist,usecgs
 real,allocatable,dimension(:,:)            :: dat
 real,allocatable,dimension(:),intent(out)  :: rho,r,pres,m,ene,temp,Xfrac,Yfrac
 real, intent(out)                          :: Mstar

 rows = 0
 usecgs = .false.
 if (present(cgsunits)) usecgs = cgsunits
 !
 !--Get path name
 !
 ierr = 0
 fullfilepath = find_phantom_datafile(filepath,'star_data_files')
 inquire(file=trim(fullfilepath),exist=iexist)
 if (.not.iexist) then
    ierr = 1
    return
 endif
 lines = get_nlines(fullfilepath) ! total number of lines in file

 open(unit=40,file=fullfilepath,status='old')
 call get_ncolumns(40,ncols,nheaderlines)
 if (nheaderlines == 6) then ! Assume file is a MESA profile, and so it has 6 header lines, and (row=3, col=2) = number of zones
    read(40,'()')
    read(40,'()')
    read(40,*) lines,lines
    read(40,'()')
    read(40,'()')
 else
    lines = lines - nheaderlines
    do i=1,nheaderlines-1
       read(40,'()')
    enddo
 endif
 if (lines <= 0) then ! file not found
    ierr = 1
    return
 endif

 read(40,'(a)') dumc! counting rows
 call string_delete(dumc,'[')
 call string_delete(dumc,']')
 allocate(dum(500)) ; dum = 'aaa'
 read(dumc,*,end=101) dum
101 do i = 1,500
    if (dum(i)=='aaa') then
       rows = i-1
       exit
    endif
 enddo

 allocate(header(rows),dat(lines,rows))
 header(1:rows) = dum(1:rows)
 deallocate(dum)
 do i = 1,lines
    read(40,*) dat(lines-i+1,1:rows)
 enddo

 allocate(m(lines),r(lines),pres(lines),rho(lines),ene(lines), &
             temp(lines),Xfrac(lines),Yfrac(lines))

 close(40)
 ! Set mass fractions to default in eos module if not in file
 Xfrac = X_in
 Yfrac = 1. - X_in - Z_in
 do i = 1,rows
    select case(trim(lcase(header(i))))
    case('mass_grams')
       m = dat(1:lines,i)
    case('mass')
       m = dat(1:lines,i)
       if (nheaderlines == 6) m = m * solarm  ! If reading MESA profile, 'mass' is in units of Msun
    case('rho','density')
       rho = dat(1:lines,i)
    case('logrho')
       rho = 10**(dat(1:lines,i))
    case('energy','e_int')
       ene = dat(1:lines,i)
    case('radius','radius_cm')
       r = dat(1:lines,i)
    case('pressure')
       pres = dat(1:lines,i)
    case('temperature')
       temp = dat(1:lines,i)
    case('x_mass_fraction_h','xfrac')
       Xfrac = dat(1:lines,i)
    case('y_mass_fraction_he','yfrac')
       Yfrac = dat(1:lines,i)
    end select
 enddo

 if (.not. usecgs) then
    m = m / umass
    r = r / udist
    pres = pres / unit_pressure
    rho = rho / unit_density
    ene = ene / unit_ergg
 endif

 Mstar = m(lines)

end subroutine read_mesa

!----------------------------------------------------------------
!+
!  Write stellar profile in format readable by read_mesa;
!  used in star setup to write softened stellar profile.
!+
!----------------------------------------------------------------
subroutine write_profile(outputpath,m,pres,temp,r,rho,ene,Xfrac,Yfrac,csound,mu)
 real, intent(in)                :: m(:),rho(:),pres(:),r(:),ene(:),temp(:)
 real, intent(in), optional      :: Xfrac(:),Yfrac(:),csound(:),mu(:)
 character(len=120), intent(in)  :: outputpath
 character(len=200)              :: headers
 integer                         :: i,noptionalcols,j
 real, allocatable               :: optionalcols(:,:)

 headers = '[    Mass   ]  [  Pressure ]  [Temperature]  [   Radius  ]  [  Density  ]  [   E_int   ]'

 ! Add optional columns
 allocate(optionalcols(size(r),10))
 noptionalcols = 0
 if (present(Xfrac)) then
    noptionalcols = noptionalcols + 1
    headers = trim(headers) // '  [   Xfrac   ]'
    optionalcols(:,noptionalcols) = Xfrac
 endif
 if (present(Yfrac)) then
    noptionalcols = noptionalcols + 1
    headers = trim(headers) // '  [   Yfrac   ]'
    optionalcols(:,noptionalcols) = Yfrac
 endif
 if (present(mu)) then
    noptionalcols = noptionalcols + 1
    headers = trim(headers) // '  [    mu     ]'
    optionalcols(:,noptionalcols) = mu
 endif
 if (present(csound)) then
    noptionalcols = noptionalcols + 1
    headers = trim(headers) // '  [Sound speed]'
    optionalcols(:,noptionalcols) = csound
 endif

 open(1, file = outputpath, status = 'replace')
 write(1,'(a)') headers
 do i=1,size(r)
    write(1,101,advance="no") m(i),pres(i),temp(i),r(i),rho(i),ene(i)
101 format (es13.6,2x,es13.6,2x,es13.6,2x,es13.6,2x,es13.6,2x,es13.6)
    do j=1,noptionalcols
       if (j==noptionalcols) then
          write(1,'(2x,es13.6)') optionalcols(i,j)
       else
          write(1,'(2x,es13.6)',advance="no") optionalcols(i,j)
       endif
    enddo
 enddo

end subroutine write_profile

!-----------------------------------------------------------------------
!+
!  Option 6:
!  Read in datafile from the KEPLER stellar evolution code
!+
!-----------------------------------------------------------------------
subroutine read_kepler_file(filepath,ng_max,n_rows,rtab,rhotab,ptab,temperature,&
                               enitab,totmass,ierr,mcut,rcut)
 use units,     only                      :udist,umass,unit_density,unit_pressure,unit_ergg
 use datafiles, only                      :find_phantom_datafile
 integer,          intent(in)            :: ng_max
 integer,          intent(out)           :: ierr,n_rows
 real,             intent(out)           :: rtab(:),rhotab(:),ptab(:),temperature(:),enitab(:)
 real,             intent(out)           :: totmass
 real,             intent(out), optional :: rcut
 real,             intent(in), optional  :: mcut
 real,             dimension(1:100)      :: test_cols
 character(len=*), intent(in)            :: filepath
 character(len=120)                      :: fullfilepath
 character(len=100000)                   :: line
 integer                                 :: i,aloc,k,j,m,s,n_cols
 integer                                 :: max_cols = 100
 real,             allocatable           :: stardata(:,:)
 logical                                 :: iexist,n_too_big
 !
 !--Get path name
 !
 ierr = 0
 fullfilepath = find_phantom_datafile(filepath,'star_data_files')
 inquire(file=trim(fullfilepath),exist=iexist)
 if (.not.iexist) then
    ierr = 1
    return
 endif
 !
 !--Read data from file
 !
 OPEN(UNIT=11, file=trim(fullfilepath))
 i = 1
 j = 0
 m=0
 s=1
 n_rows = 0
 n_cols = 0
 n_too_big = .false.
 !
 !--The first loop calculates the number of rows, columns and comments in kepler file.
 !
 do
    read(11, '(a)', iostat=ierr) line
    if (ierr/=0) exit

    if (index(line,'#')  /=  0) then
       j = j + 1

    else
       if (s==1) then
          !calculate number of columns
          do m=1, max_cols

             read(line,*,iostat=ierr) test_cols(1:m)
             if (ierr/=0) exit

          enddo
       endif

       s = s+1
       !calculate number of rows
       n_rows = n_rows + 1

    endif
 enddo
 close(11)

 n_cols = m-1
 !
 !--Check if the number of rows is 0 or greater than ng_max.
 !
 if (n_rows < 1) then
    ierr = 2
    return
 endif

 if (n_rows >= ng_max) n_too_big = .true.

 if (n_too_big) then
    ierr = 3
    return
 endif

 ierr = 0

 !Allocate memory for saving data
 allocate(stardata(n_rows, n_cols))
 !
 !--Read the file again and save it in stardata tensor.
 !
 open(13, file=trim(fullfilepath))
 do i = 1,j
    read(13,*,iostat=ierr)
 enddo

 do k=1,n_rows
    read(13,*,iostat=ierr) stardata(k,:)
 enddo
 close(13)
 !
 !--convert relevant data from CGS to code units
 !
 !radius
 stardata(1:n_rows,4)  = stardata(1:n_rows,4)/udist
 rtab(1:n_rows)        = stardata(1:n_rows,4)

 !density
 stardata(1:n_rows,6)  = stardata(1:n_rows,6)/unit_density
 rhotab(1:n_rows)      = stardata(1:n_rows,6)

 !mass
 stardata(1:n_rows,3)  = stardata(1:n_rows,3)/umass
 totmass               = stardata(n_rows,3)

 !pressure
 stardata(1:n_rows,8)  = stardata(1:n_rows,8)/unit_pressure
 ptab(1:n_rows)        = stardata(1:n_rows,8)

 !temperature
 temperature(1:n_rows) = stardata(1:n_rows,7)

 !specific internal energy
 stardata(1:n_rows,9)  = stardata(1:n_rows,9)/unit_ergg
 enitab(1:n_rows)      = stardata(1:n_rows,9)

 if (present(rcut) .and. present(mcut)) then
    aloc = minloc(abs(stardata(1:n_rows,1) - mcut),1)
    rcut = rtab(aloc)
    print*, 'rcut = ', rcut
 endif
 print*, 'Finished reading KEPLER file'
 print*, '------------------------------------------------------------'

end subroutine read_kepler_file
!-----------------------------------------------------------------------
!+
!  Option 7:
!  Calculates a Bonnor-Ebert sphere
!
!  Examples:
!  To reproduce the sphere in Wurster & Bate (2019):
!     iBEparam = 5, normalised radius = 7.45; physical mass = 1Msun; fac = 1.0
!  To reproduce the sphere in Saiki & Machida (2020):
!     iBEparam = 4, normalised radius = 12.9; physical radius = 5300au; fac = 6.98
!     cs_sphere = 18900cm/s (this is 10K, assuming gamma = 1)
!     density_contrast = 4.48
!  To define both physical radius & mass, the overdensity factor is automatically changed
!+
!-----------------------------------------------------------------------
subroutine rho_bonnorebert(iBEparam,central_density,edge_density,rBE,xBE,mBE,facBE,csBE,gmw,npts,iBElast,rtab,rhotab,ierr)
 use physcon, only:au,pc,mass_proton_cgs,solarm
 use units,   only:umass,udist
 integer, intent(in)    :: iBEparam,npts
 integer, intent(out)   :: iBElast,ierr
 real,    intent(in)    :: csBE,gmw
 real,    intent(inout) :: rBE,mBE,xBE,facBE,central_density
 real,    intent(out)   :: edge_density,rtab(:),rhotab(:)
 integer                :: j,iu
 real                   :: xi,phi,func,containedmass,dxi,dfunc,rho,dphi
 real                   :: rBE0,fac_close
 real                   :: mtab(npts)
 logical                :: write_BE_profile = .true.
 logical                :: override_critical = .false.  ! if true, will not error out if the density ratio is too small

 !--Initialise variables
 xi             = 0.0
 phi            = 0.0
 func           = 0.0
 containedmass  = 0.0
 dxi            = 5.01*6.45/float(npts)
 dfunc          = (-exp(phi))*dxi
 rtab           = 0.  ! array of radii
 mtab           = 0.  ! array of enclosed masses
 rhotab         = 0.  ! array of densities
 rhotab(1)      = 1.  ! initial normalised density
 rho            = 1.
 ierr           = 0

 ! initialise variables not required for chosen iBEparam (to avoid errors)
 if (iBEparam/=1 .and. iBEparam/=2 .and. iBEparam/=3) central_density = 3.8d-18
 if (iBEparam/=1 .and. iBEparam/=4 .and. iBEparam/=6) rBE   = 7000.*au/udist
 if (iBEparam/=2 .and. iBEparam/=4 .and. iBEparam/=5) xBE   = 7.45
 if (iBEparam/=3 .and. iBEparam/=5 .and. iBEparam/=6) mBE   = 1.0*solarm/umass
 if (iBEparam/=4 .and. iBEparam/=5)                   facBE = 1.0

 !--Calculate a normalised BE profile out to 5 critical radii
 do j = 2,npts
    xi    = (j-1)*dxi
    func  = func + dfunc
    dphi  = func*dxi
    phi   = phi + dphi
    dfunc = (-exp(phi) - 2.0*func/xi)*dxi
    rho   = exp(phi)
    containedmass = containedmass + fourpi*xi*xi*rho*dxi
    rtab(j)       = xi
    mtab(j)       = containedmass
    rhotab(j)     = rho
 enddo
 iBElast = npts

 !--Determine scaling factors for the BE
 fac_close = 1000.
 if (iBEparam==4 .or. iBEparam==6) central_density = (csBE*xBE/rBE)**2/fourpi
 if (iBEparam==5) then
    do j = 1, npts
       if (rtab(j) < xBE) iBElast = j
    enddo
    central_density = (csBE**3*mtab(iBElast)*facBE/mBE)**2/fourpi**3
 endif
 rBE0 = csBE/sqrt(fourpi*central_density)

 !--Scale the entire profile to match the input parameters
 do j = 1, npts
    if (iBEparam == 2 .and. rtab(j) < xBE) iBElast = j

    rtab(j)   = rBE0 * rtab(j)
    mtab(j)   = mtab(j) * central_density*rBE0**3
    rhotab(j) = central_density * rhotab(j)

    if ((iBEparam == 1 .or. iBEparam==6 .or. iBEparam == 4) .and. rtab(j) < rBE) then
       iBElast = j
    elseif (iBEparam == 3 .and. mtab(j) < mBE) then
       iBElast = j
    endif
 enddo
 !--Set the remaining properties
 if (iBEparam==4) then
    central_density = central_density*facBE
    mtab(iBElast)   = mtab(iBElast)*facBE
    rhotab          = rhotab*facBE
 endif
 if (iBEparam==5) then
    central_density = central_density/sqrt(facBE)
    mtab(iBElast)   = mtab(iBElast)*facBE
    rhotab          = rhotab/sqrt(facBE)
 endif
 if (iBEparam==6) then
    facBE           = mBE/mtab(iBElast)
    central_density = central_density/sqrt(facBE)
    mtab(iBElast)   = mtab(iBElast)*facBE
    rhotab          = rhotab/sqrt(facBE)
 endif
 mBE = mtab(iBElast)
 rBE = rtab(iBElast)
 xBE = rBE/rBE0
 edge_density = rhotab(iBElast)

 print*, '------ BE sphere properties --------'
 print*, ' Value of central density (code units) = ',central_density
 print*, ' Value of central density (g/cm^3)     = ',central_density*umass/udist**3
 print*, ' Value of central density (1/cm^3)     = ',central_density*umass/(gmw*mass_proton_cgs*udist**3)
 print*, ' Radius (dimensionless) = ',xBE
 print*, ' Radius (code)          = ',rBE
 print*, ' Radius (cm)            = ',rBE*udist
 print*, ' Radius (au)            = ',rBE*udist/au
 print*, ' Radius (pc)            = ',rBE*udist/pc
 print*, ' Total mass (Msun)      = ',mBE*umass/solarm
 print*, ' Overdensity factor     = ',facBE
 print*, ' rho_c/rho_outer             = ',central_density/edge_density
 print*, ' Equilibrium temperature (K) = ',mBE*umass*pc/(rBE*udist*solarm*2.02)
 print*, '------------------------------------'

 !--Error out if required
 if (central_density/rhotab(iBElast) < 14.1) then
    print*, 'The density ratio between the central and edge densities is too low and the sphere will not collapse.'
    if (.not. override_critical) then
       print*, 'Aborting.'
       ierr = 1
       return
    endif
 endif

 !--Write the scaled BE profile that is to be used
 if (write_BE_profile) then
    open(newunit=iu,file='BonnorEbert.txt')
    write(iu,'(a)') "# [01     r(code)]   [02 M_enc(code)]   [03   rho(code)]"
    do j = 1,iBElast
       write(iu,'(3(1pe18.10,1x))') rtab(j),mtab(j),rhotab(j)
    enddo
    close(iu)
 endif

end subroutine rho_bonnorebert
!-----------------------------------------------------------------------
!  Prompts for the BE sphere
!  (see setup_sphereinbox for read/write_setup commands)
!-----------------------------------------------------------------------
subroutine prompt_BEparameters(iBEparam,rho_cen,rad_phys,rad_norm,mass_phys,fac,umass,udist,au,solarm)
 use prompting, only:prompt
 integer,      intent(out) :: iBEparam
 real,         intent(out) :: rho_cen,rad_phys,rad_norm,mass_phys,fac
 real,         intent(in)  :: au,solarm
 real(kind=8), intent(in)  :: umass,udist

 print*, 'Please select parameters used to fit the BE sphere:'
 print*, 'The pairs are: '
 print*, '  1: central density & physical radius'
 print*, '  2: central density & normalised radius'
 print*, '  3: central density & physical mass'
 print*, '  4: normalised radius & physical radius & overdensity factor'
 print*, '  5: normalised radius & physical mass   & overdensity factor'
 print*, '  6: physical radius & physical mass'
 iBEparam = 5
 call prompt('Please enter your choice now: ',iBEparam,1,6)

 !--Default values
 rho_cen   = 3.8d-18
 rad_phys  = 7000.*au/udist
 rad_norm  = 7.45
 mass_phys = 1.0*solarm/umass
 fac       = 1.0 ! This might need to be removed

 !--Ask for the values depending on iBEparam
 if (iBEparam==1 .or. iBEparam==2 .or. iBEparam==3) call prompt('Enter the central density [cgs]: ',rho_cen,0.)
 if (iBEparam==1 .or. iBEparam==4 .or. iBEparam==6) call prompt('Enter the physical radius [code]: ',rad_phys,0.)
 if (iBEparam==2 .or. iBEparam==4 .or. iBEparam==5) call prompt('Enter the normalised radius (critical==6.45): ',rad_norm,0.)
 if (iBEparam==3 .or. iBEparam==5 .or. iBEparam==6) call prompt('Enter the physical mass [code]: ',mass_phys,0.)
 if (iBEparam==4 .or. iBEparam==5) call prompt('Enter density enhancement factor (for mass = fac*mBE): ',fac,1.)
 rho_cen = rho_cen * udist**3/umass ! convert to code units

end subroutine prompt_BEparameters

end module rho_profile
