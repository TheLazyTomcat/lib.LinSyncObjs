unit LinSyncObjs;

{$IF Defined(LINUX) and Defined(FPC)}
  {$DEFINE Linux}
{$ELSE}
  {$MESSAGE FATAL 'Unsupported operating system.'}
{$IFEND}

{$IFDEF FPC}
  {$MODE ObjFPC}
  {$MODESWITCH DuplicateLocals+}
  {$DEFINE FPC_DisableWarns}
  {$MACRO ON}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, BaseUnix,
  AuxTypes, AuxClasses, NamedSharedItems;

{$IFDEF FPC_DisableWarns}
  {$DEFINE FPCDWM}
  {$DEFINE W3018:={$WARN 3018 OFF}} // Constructor should be public
{$ENDIF}

{===============================================================================
    Library-specific exceptions
===============================================================================}

type
  ELSOException = class(Exception);

  ELSOSysInitError  = class(ELSOException);
  ELSOSysFinalError = class(ELSOException);
  ELSOSysOpError    = class(ELSOException);

  ELSOOpenError       = class(ELSOException);
  ELSOInvalidLockType = class(ELSOException);
  ELSOInvalidObject   = class(ELSOException);

{===============================================================================
--------------------------------------------------------------------------------
                                TCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{
  To properly use the TCriticalSection object, create one instance and then
  pass this one instance to other threads that need to be synchronized.

  Make sure to only free it once.

  You can also set the proterty FreeOnRelease to true (by default false) and
  then use the build-in reference counting - call method Acquire for each
  thread using it (including the one that created it) and method Release every
  time a thread will stop using it. When reference count reaches zero in a
  call to Release, the object will be automatically freed.
}
{===============================================================================
    TCriticalSection - class declaration
===============================================================================}
type
  TCriticalSection = class(TCustomRefCountedObject)
  protected
    fMutex: pthread_mutex_t;
    procedure Initialize; virtual;
    procedure Finalize; virtual;
  public
    constructor Create;
    destructor Destroy; override;
    Function TryEnter: Boolean; virtual;
    procedure Enter; virtual;
    procedure Leave; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                 TLinSyncObject
--------------------------------------------------------------------------------
===============================================================================}
type
  TLSOSharedUserData = packed array[0..31] of Byte;
  PLSOSharedUserData = ^TLSOSharedUserData;

type
  TLSOWaitResult = (wrSignaled,wrTimeout,wrError);

  TLSOLockType = (ltInvalid,ltEvent,ltMutex,ltSemaphore,ltCondVar,ltBarrier,
                  ltRWLock,ltSimpleEvent,ltAdvancedEVent);

{===============================================================================
    TLinSyncObject - class declaration
===============================================================================}
type
  TLinSyncObject = class(TCustomObject)
  protected
    fLastError:       Integer;
    fName:            String;
    fProcessShared:   Boolean;
    fNamedSharedItem: TNamedSharedItem;   // unused in thread-shared mode
    fSharedData:      Pointer;
    fLockPtr:         Pointer;
    // getters, setters
    Function GetSharedUserDataPtr: PLSOSharedUserData; virtual;
    Function GetSharedUserData: TLSOSharedUserData; virtual;
    procedure SetSharedUserData(Value: TLSOSharedUserData); virtual;
    // lock management methods
    class Function GetLockType: TLSOLockType; virtual; abstract;
    procedure CheckAndSetLockType; virtual;
    procedure ResolveLockPtr; virtual; abstract;
    procedure InitializeLock(InitializingData: PtrUInt); virtual; abstract;
    procedure FinalizeLock; virtual; abstract;
    // object initialization/finalization
    procedure Initialize(const Name: String; InitializingData: PtrUInt); overload; virtual;
    // following overload can be used only to open existing process-shared objects
    procedure Initialize(const Name: String); overload; virtual;
    procedure Finalize; virtual;
  {$IFDEF FPCDWM}{$PUSH}W3018{$ENDIF}
    constructor ProtectedCreate(const Name: String; InitializingData: PtrUInt); virtual;
  {$IFDEF FPCDWM}{$POP}{$ENDIF}
  public
    constructor Create(const Name: String); overload; virtual;
    constructor Create; overload; virtual;
    constructor Open(const Name: String); virtual;
    constructor DuplicateFrom(SourceObject: TLinSyncObject); virtual;
    destructor Destroy; override;
    // properties
    property LastError: Integer read fLastError;
    property Name: String read fName;
    property ProcessShared: Boolean read fProcessShared;
    property SharedUserDataPtr: PLSOSharedUserData read GetSharedUserDataPtr;
    property SharedUserData: TLSOSharedUserData read GetSharedUserData write SetSharedUserData;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                              TWrapperLinSynObject
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TWrapperLinSynObject - class declaration
===============================================================================}
type
  TWrapperLinSynObject = class(TLinSyncObject);

{===============================================================================
--------------------------------------------------------------------------------
                            TImplementorLinSynObject
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TImplementorLinSynObject - class declaration
===============================================================================}
type
  TImplementorLinSynObject = class(TLinSyncObject);

{===============================================================================
--------------------------------------------------------------------------------
                                     TMutex
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TMutex - class declaration
===============================================================================}
type
  TMutex = class(TWrapperLinSynObject)
  protected
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
  public
    procedure LockMutex; virtual;
    Function TryLockMutex: Boolean; virtual;
    Function TimedLockMutex(Timeout: UInt32): TLSOWaitResult; virtual;
    procedure UnlockMutex; virtual;
    Function LockMutexSilent: Boolean; virtual;
    Function TryLockMutexSilent: Boolean; virtual;
    Function UnlockMutexSilent: Boolean; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                   TSemaphore
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSemaphore - class declaration
===============================================================================}
type
  TSemaphore = class(TWrapperLinSynObject)
  protected
    fInitialValue:  cUnsigned;
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
  public
    constructor Create(const Name: String; InitialValue: cUnsigned); overload; virtual;
    constructor Create(InitialValue: cUnsigned); overload; virtual;
    constructor Create(const Name: String); override;
    constructor Create; override;
    //procedure GetValue(out Value: cInt); virtual;
    procedure WaitSemaphore; virtual;
    Function TryWaitSemaphore: Boolean; virtual;
    Function TimedWaitSemaphore(Timeout: UInt32): TLSOWaitResult; virtual;
    procedure PostSemaphore; virtual;
    //Function GetValueSilent(out Value: cInt): Boolean; virtual;
    Function WaitSemaphoreSilent: Boolean; virtual;
    Function TryWaitSemaphoreSilent: Boolean; virtual;
    Function PostSemaphoreSilent: Boolean; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                               Utility functions
--------------------------------------------------------------------------------
===============================================================================}
{
  WaitResultToStr returns textual representation of a given wait result.
  Meant mainly for debugging.
}
Function WaitResultToStr(WaitResult: TLSOWaitResult): String;

implementation

uses
  UnixType, Linux, pThreads, Errors,
  InterlockedOps;

{$IFDEF FPC_DisableWarns}
  {$DEFINE FPCDWM}
  {$DEFINE W5024:={$WARN 5024 OFF}} // Parameter "$1" not used
{$ENDIF}

//------------------------------------------------------------------------------

threadvar
  ThrErrorCode: cInt;

Function CheckResErr(ReturnedValue: cInt): Boolean;
begin
Result := ReturnedValue = 0;
If Result then
  ThrErrorCode := 0
else
  ThrErrorCode := ReturnedValue;
end;

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

Function CheckErr(ReturnedValue: cInt): Boolean;
begin
Result := ReturnedValue = 0;
If Result then
  ThrErrorCode := 0
else
  ThrErrorCode := errno;
end;

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

Function errno_ptr: pcInt; cdecl; external name '__errno_location';

Function CheckErrAlt(ReturnedValue: cInt): Boolean;
begin
Result := ReturnedValue = 0;
If Result then
  ThrErrorCode := 0
else
  ThrErrorCode := errno_ptr^;
end;

{===============================================================================
--------------------------------------------------------------------------------
                                TCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TCriticalSection - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TCriticalSection - protected methods
-------------------------------------------------------------------------------}

procedure TCriticalSection.Initialize;
var
  MutexAttr:  pthread_mutexattr_t;
begin
If CheckResErr(pthread_mutexattr_init(@MutexAttr)) then
  try
    If not CheckResErr(pthread_mutexattr_settype(@MutexAttr,PTHREAD_MUTEX_RECURSIVE)) then
      raise ELSOSysOpError.CreateFmt('TCriticalSection.Initialize: ' +
        'Failed to set mutex attribute TYPE (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckResErr(pthread_mutex_init(@fMutex,@MutexAttr)) then
      raise ELSOSysInitError.CreateFmt('TCriticalSection.Initialize: ' +
        'Failed to initialize mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckResErr(pthread_mutexattr_destroy(@MutexAttr)) then
      raise ELSOSysFinalError.CreateFmt('TCriticalSection.Initialize: ' +
        'Failed to destroy mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TCriticalSection.Initialize: ' +
       'Failed to initialize mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

procedure TCriticalSection.Finalize;
begin
If not CheckResErr(pthread_mutex_destroy(@fMutex)) then
  raise ELSOSysFinalError.CreateFmt('TCriticalSection.Finalize: ' +
    'Failed to destroy mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TCriticalSection - public methods
-------------------------------------------------------------------------------}

constructor TCriticalSection.Create;
begin
inherited Create;
Initialize;
end;

//------------------------------------------------------------------------------

destructor TCriticalSection.Destroy;
begin
Finalize;
inherited;
end;
//------------------------------------------------------------------------------

Function TCriticalSection.TryEnter: Boolean;
begin
Result := CheckResErr(pthread_mutex_trylock(@fMutex));
If not Result and (ThrErrorCode <> ESysEBUSY) then
  raise ELSOSysOpError.CreateFmt('TCriticalSection.TryEnter: ' +
    'Failed to try-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

procedure TCriticalSection.Enter;
begin
If not CheckResErr(pthread_mutex_lock(@fMutex)) then
  raise ELSOSysOpError.CreateFmt('TCriticalSection.Enter: ' +
    'Failed to lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

procedure TCriticalSection.Leave;
begin
If not CheckResErr(pthread_mutex_unlock(@fMutex)) then
  raise ELSOSysOpError.CreateFmt('TCriticalSection.Leave: ' +
    'Failed to unlock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;


{===============================================================================
--------------------------------------------------------------------------------
                                 TLinSyncObject
--------------------------------------------------------------------------------
===============================================================================}
const
  LSO_SHARED_NAMESPACE = 'lso_shared';

type
  TLSOSimpleEvent = record
  end;
  PLSOSimpleEvent = {%H-}^TLSOSimpleEvent;

type
  TLSOEvent = record
  end;
  PLSOEvent = {%H-}^TLSOEvent;

type
  TLSOAdvancedEvent = record
  end;
  PLSOAdvancedEvent = {%H-}^TLSOAdvancedEvent;

type
  TLSOSharedData = record
    SharedUserData: TLSOSharedUserData;
    RefCount:       Int32;
    case LockType: TLSOLockType of
      ltEvent:          (Event:         TLSOEvent);
      ltMutex:          (Mutex:         pthread_mutex_t);
      ltSemaphore:      (Semaphore:     sem_t);
      ltCondVar:        (CondVar:       pthread_cond_t);
      ltBarrier:        (Barrier:       pthread_barrier_t);
      ltRWLock:         (RWLock:        pthread_rwlock_t);
      ltSimpleEvent:    (SimpleEvent:   TLSOSimpleEvent);
      ltAdvancedEVent:  (AdvancedEvent: TLSOAdvancedEvent)
  end;
  PLSOSharedData = ^TLSOSharedData;

//------------------------------------------------------------------------------

procedure ResolveTimeout(Timeout: UInt32; out TimeoutSpec: timespec);
begin
If not CheckErr(clock_gettime(CLOCK_REALTIME,@TimeoutSpec)) then
  raise ELSOSysOpError.CreateFmt('ResolveTimeout: ' +
    'Failed to obtain current time (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
TimeoutSpec.tv_sec := TimeoutSpec.tv_sec + time_t(Timeout div 1000);
TimeoutSpec.tv_nsec := TimeoutSpec.tv_nsec + clong((Timeout mod 1000) * 1000000);
If TimeoutSpec.tv_nsec > 1000000000 then
  begin
    Inc(TimeoutSpec.tv_sec);
    TimeoutSpec.tv_nsec := TimeoutSpec.tv_nsec - 1000000000;
  end;
end;

{===============================================================================
    TLinSyncObject - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TLinSyncObject - protected methods
-------------------------------------------------------------------------------}

Function TLinSyncObject.GetSharedUserDataPtr: PLSOSharedUserData;
begin
Result := Addr(PLSOSharedData(fSharedData)^.SharedUserData);
end;

//------------------------------------------------------------------------------

Function TLinSyncObject.GetSharedUserData: TLSOSharedUserData;
begin
Move(GetSharedUserDataPtr^,Addr(Result)^,SizeOf(TLSOSharedUserData));
end;

//------------------------------------------------------------------------------

procedure TLinSyncObject.SetSharedUserData(Value: TLSOSharedUserData);
begin
Move(Value,GetSharedUserDataPtr^,SizeOf(TLSOSharedUserData));
end;

//------------------------------------------------------------------------------

procedure TLinSyncObject.CheckAndSetLockType;
begin
If PLSOSharedData(fSharedData)^.LockType <> ltInvalid then
  begin
    If PLSOSharedData(fSharedData)^.LockType <> GetLockType then
      raise ELSOInvalidLockType.CreateFmt('TLinSyncObject.CheckAndSetLockType: ' +
        'Existing lock is of incompatible type (%d)',[Ord(PLSOSharedData(fSharedData)^.LockType)]);
  end
else PLSOSharedData(fSharedData)^.LockType := GetLockType;
end;

//------------------------------------------------------------------------------

procedure TLinSyncObject.Initialize(const Name: String; InitializingData: PtrUInt);
begin
fLastError := 0;
fName := Name;
fProcessShared := Length(fName) > 0;
// create/open shared data
If fProcessShared then
  begin
    fNamedSharedItem := TNamedSharedItem.Create(fName,SizeOf(TLSOSharedData),LSO_SHARED_NAMESPACE);
    fSharedData := fNamedSharedItem.Memory;
    fNamedSharedItem.GlobalLock;
    try
      CheckAndSetLockType;
      Inc(PLSOSharedData(fSharedData)^.RefCount);
      If PLSOSharedData(fSharedData)^.RefCount <= 1 then
        InitializeLock(InitializingData);
    finally
      fNamedSharedItem.GlobalUnlock;
    end;
  end
else
  begin
    fSharedData := AllocMem(SizeOf(TLSOSharedData));
    CheckAndSetLockType;
    InterlockedStore(PLSOSharedData(fSharedData)^.RefCount,1);
    InitializeLock(InitializingData);
  end;
ResolveLockPtr;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

procedure TLinSyncObject.Initialize(const Name: String);
begin
If Length(Name) > 0 then
  begin
    fLastError := 0;
    fName := Name;
    fProcessShared := True;
    fNamedSharedItem := TNamedSharedItem.Create(fName,SizeOf(TLSOSharedData),LSO_SHARED_NAMESPACE);
    fSharedData := fNamedSharedItem.Memory;
    fNamedSharedItem.GlobalLock;
    try
      CheckAndSetLockType;
      Inc(PLSOSharedData(fSharedData)^.RefCount);
      If PLSOSharedData(fSharedData)^.RefCount <= 1 then
        raise ELSOOpenError.Create('TLinSyncObject.Initialize: Cannot open uninitialized object.');
    finally
      fNamedSharedItem.GlobalUnlock;
    end;
    ResolveLockPtr;
  end
else raise ELSOOpenError.Create('TLinSyncObject.Initialize: Cannot open unnamed object.');
end;

//------------------------------------------------------------------------------

procedure TLinSyncObject.Finalize;
begin
If Assigned(fSharedData) then
  begin
    If fProcessShared then
      begin
        fNamedSharedItem.GlobalLock;
        try
          Dec(PLSOSharedData(fSharedData)^.RefCount);
          If PLSOSharedData(fSharedData)^.RefCount <= 0 then
            begin
              FinalizeLock;
              PLSOSharedData(fSharedData)^.RefCount := 0;
            end;
        finally
          fNamedSharedItem.GlobalUnlock;
        end;
        FreeAndNil(fNamedSharedItem);
      end
    else
      begin
        If InterlockedDecrement(PLSOSharedData(fSharedData)^.RefCount) <= 0 then
          begin
            FinalizeLock;
            FreeMem(fSharedData,SizeOf(TLSOSharedData));
          end;
      end;
    fSharedData := nil;
    fLockPtr := nil;
  end;
end;

//------------------------------------------------------------------------------

constructor TLinSyncObject.ProtectedCreate(const Name: String; InitializingData: PtrUInt);
begin
inherited Create;
Initialize(Name,InitializingData);
end;

{-------------------------------------------------------------------------------
    TLinSyncObject - public methods
-------------------------------------------------------------------------------}

constructor TLinSyncObject.Create(const Name: String);
begin
ProtectedCreate(Name,0);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TLinSyncObject.Create;
begin
ProtectedCreate('',0);
end;

//------------------------------------------------------------------------------

constructor TLinSyncObject.Open(const Name: String);
begin
inherited Create;
Initialize(Name);
end;

//------------------------------------------------------------------------------

constructor TLinSyncObject.DuplicateFrom(SourceObject: TLinSyncObject);
begin
inherited Create;
If SourceObject is Self.ClassType then
  begin
    If not SourceObject.ProcessShared then
      begin
        fProcessShared := False;
      {
        Increase reference counter. If it is above 1, all is good and continue.
        But if it is below or equal to 1, it means the source was probably
        (being) destroyed - raise an exception.
      }
        If InterlockedIncrement(PLSOSharedData(SourceObject.fSharedData)^.RefCount) > 1 then
          begin
            fLastError := 0;
            fName := '';
            fSharedData := SourceObject.fSharedData;
            ResolveLockPtr; // normally called from Initialize
          end
        else raise ELSOInvalidObject.Create('TLinSyncObject.DuplicateFrom: ' +
               'Source object is in an inconsistent state.');
      end
    else Initialize(SourceObject.Name); // corresponds to open constructor
  end
else raise ELSOInvalidObject.CreateFmt('TLinSyncObject.DuplicateFrom: ' +
       'Incompatible source object (%s).',[SourceObject.ClassName]);
end;

//------------------------------------------------------------------------------

destructor TLinSyncObject.Destroy;
begin
Finalize;
inherited;
end;


{===============================================================================
--------------------------------------------------------------------------------
                                     TMutex
--------------------------------------------------------------------------------
===============================================================================}

Function pthread_mutex_timedlock(mutex: ppthread_mutex_t; abstime: ptimespec): cInt; cdecl; external;

{===============================================================================
    TMutex - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TMutex - protected methods
-------------------------------------------------------------------------------}

class Function TMutex.GetLockType: TLSOLockType;
begin
Result := ltMutex;
end;

//------------------------------------------------------------------------------

procedure TMutex.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.Mutex);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
procedure TMutex.InitializeLock(InitializingData: PtrUInt);
var
  MutexAttr:  pthread_mutexattr_t;
begin
If CheckResErr(pthread_mutexattr_init(@MutexAttr)) then
  try
    If not CheckResErr(pthread_mutexattr_settype(@MutexAttr,PTHREAD_MUTEX_RECURSIVE)) then
      raise ELSOSysOpError.CreateFmt('TMutex.InitializeLock: ' +
        'Failed to set mutex attribute TYPE (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If fProcessShared then
      If not CheckResErr(pthread_mutexattr_setpshared(@MutexAttr,PTHREAD_PROCESS_SHARED)) then
        raise ELSOSysOpError.CreateFmt('TMutex.InitializeLock: ' +
          'Failed to set mutex attribute PSHARED (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckResErr(pthread_mutex_init(Addr(PLSOSharedData(fSharedData)^.Mutex),@MutexAttr)) then
      raise ELSOSysInitError.CreateFmt('TMutex.InitializeLock: ' +
        'Failed to initialize mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckResErr(pthread_mutexattr_destroy(@MutexAttr)) then
      raise ELSOSysFinalError.CreateFmt('TMutex.InitializeLock: ' +
        'Failed to destroy mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TMutex.InitializeLock: ' +
       'Failed to initialize mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TMutex.FinalizeLock;
begin
If not CheckResErr(pthread_mutex_destroy(Addr(PLSOSharedData(fSharedData)^.Mutex))) then
  raise ELSOSysFinalError.CreateFmt('TMutex.FinalizeLock: ' +
    'Failed to destroy mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TMutex - public methods
-------------------------------------------------------------------------------}

procedure TMutex.LockMutex;
begin
If not CheckResErr(pthread_mutex_lock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TMutex.LockMutex: ' +
    'Failed to lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TMutex.TryLockMutex: Boolean;
begin
Result := CheckResErr(pthread_mutex_trylock(fLockPtr));
If not Result and (ThrErrorCode <> ESysEBUSY) then
  raise ELSOSysOpError.CreateFmt('TMutex.TryLockMutex: ' +
    'Failed to try-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TMutex.TimedLockMutex(Timeout: UInt32): TLSOWaitResult;
var
  TimeoutSpec:  timespec;
begin
ResolveTimeout(Timeout,TimeoutSpec);
If not CheckResErr(pthread_mutex_timedlock(fLockPtr,@TimeoutSpec)) then
  begin
    If ThrErrorCode <> ESysETIMEDOUT then
      begin
        Result := wrError;
        fLastError := Integer(ThrErrorCode);
      end
    else Result := wrTimeout;
  end
else Result := wrSignaled;
end;

//------------------------------------------------------------------------------

procedure TMutex.UnlockMutex;
begin
If not CheckResErr(pthread_mutex_unlock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TMutex.UnlockMutex: ' +
    'Failed to unlock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TMutex.LockMutexSilent: Boolean;
begin
Result := CheckResErr(pthread_mutex_lock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TMutex.TryLockMutexSilent: Boolean;
begin
Result := CheckResErr(pthread_mutex_trylock(fLockPtr));
If not Result and (ThrErrorCode = ESysEBUSY) then
  fLastError := 0
else
  fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TMutex.UnlockMutexSilent: Boolean;
begin
Result := CheckResErr(pthread_mutex_unlock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;


{===============================================================================
--------------------------------------------------------------------------------
                                   TSemaphore
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSemaphore - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TSemaphore - protected methods
-------------------------------------------------------------------------------}

class Function TSemaphore.GetLockType: TLSOLockType;
begin
Result := ltSemaphore;
end;

//------------------------------------------------------------------------------

procedure TSemaphore.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.Semaphore);
end;

//------------------------------------------------------------------------------

procedure TSemaphore.InitializeLock(InitializingData: PtrUInt);
begin
If not CheckErrAlt(sem_init(Addr(PLSOSharedData(fSharedData)^.Semaphore),Ord(fProcessShared),cUnsigned(InitializingData))) then
  raise ELSOSysInitError.CreateFmt('TSemaphore.InitializeLock: ' +
    'Failed to initialize semaphore (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

procedure TSemaphore.FinalizeLock;
begin
If not CheckErrAlt(sem_destroy(Addr(PLSOSharedData(fSharedData)^.Semaphore))) then
  raise ELSOSysFinalError.CreateFmt('TSemaphore.FinalizeLock: ' +
    'Failed to destroy semaphore (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TSemaphore - public methods
-------------------------------------------------------------------------------}

constructor TSemaphore.Create(const Name: String; InitialValue: cUnsigned);
begin
ProtectedCreate(Name,PtrUInt(InitialValue));
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TSemaphore.Create(InitialValue: cUnsigned);
begin
ProtectedCreate('',PtrUInt(InitialValue))
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TSemaphore.Create(const Name: String);
begin
ProtectedCreate(Name,0);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TSemaphore.Create;
begin
ProtectedCreate('',0);
end;

//------------------------------------------------------------------------------

procedure TSemaphore.WaitSemaphore;
var
  ExitWait: Boolean;
begin
repeat
  ExitWait := True;
  If not CheckErrAlt(sem_wait(fLockPtr)) then
    begin
      If ThrErrorCode = ESysEINTR then
        ExitWait := False
      else
        raise ELSOSysOpError.CreateFmt('TSemaphore.WaitSemaphore: ' +
          'Failed to wait on semaphore (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    end;
until ExitWait;
end;

//------------------------------------------------------------------------------

Function TSemaphore.TryWaitSemaphore: Boolean;
var
  ExitWait: Boolean;
begin
repeat
  ExitWait := True;
  Result := CheckErrAlt(sem_trywait(fLockPtr));
  If not Result then
    case ThrErrorCode of
      ESysEINTR:  ExitWait := False;
      ESysEAGAIN:;// do nothing (exit with result being false)
    else
      raise ELSOSysOpError.CreateFmt('TSemaphore.TryWaitSemaphore: ' +
        'Failed to try-wait on semaphore (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    end;
until ExitWait;
end;

//------------------------------------------------------------------------------

Function TSemaphore.TimedWaitSemaphore(Timeout: UInt32): TLSOWaitResult;
var
  TimeoutSpec:  timespec;
  ExitWait:     Boolean;
begin
ResolveTimeout(Timeout,TimeoutSpec);
repeat
  ExitWait := True;
  If not CheckErrAlt(sem_timedwait(fLockPtr,@TimeoutSpec)) then
    case ThrErrorCode of
      ESysEINTR:      ExitWait := False;  // no need to reset timeout, it is absolute
      ESysETIMEDOUT:  Result := wrTimeout;
    else
      Result := wrError;
      fLastError := ThrErrorCode;
    end
  else Result := wrSignaled;
until ExitWait;
end;

//------------------------------------------------------------------------------

procedure TSemaphore.PostSemaphore;
begin
If not CheckErrAlt(sem_post(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TSemaphore.PostSemaphore: ' +
    'Failed to post semaphore (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TSemaphore.WaitSemaphoreSilent: Boolean;
var
  ExitWait: Boolean;
begin
repeat
  Result := CheckErrAlt(sem_wait(fLockPtr));
  ExitWait := Result or (ThrErrorCode <> ESysEINTR);
until ExitWait;
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TSemaphore.TryWaitSemaphoreSilent: Boolean;
var
  ExitWait: Boolean;
begin
repeat
  Result := CheckErrAlt(sem_trywait(fLockPtr));
  ExitWait := Result or (ThrErrorCode <> ESysEINTR);
until ExitWait;
If not Result and (ThrErrorCode = ESysEAGAIN) then
  fLastError := 0
else
  fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TSemaphore.PostSemaphoreSilent: Boolean;
begin
Result := CheckErrAlt(sem_post(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;


{===============================================================================
--------------------------------------------------------------------------------
                               Utility functions
--------------------------------------------------------------------------------
===============================================================================}

Function WaitResultToStr(WaitResult: TLSOWaitResult): String;
const
  WR_STRS: array[TLSOWaitResult] of String = ('Signaled','Timeout','Error');
begin
If (WaitResult >= Low(TLSOWaitResult)) and (WaitResult <= High(TLSOWaitResult)) then
  Result := WR_STRS[WaitResult]
else
  Result := '<invalid>';
end;

end.

