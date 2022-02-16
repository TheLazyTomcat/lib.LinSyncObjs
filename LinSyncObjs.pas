unit LinSyncObjs;

{$IF Defined(LINUX) and Defined(FPC)}
  {$DEFINE Linux}
{$ELSE}
  {$MESSAGE FATAL 'Unsupported operating system.'}
{$IFEND}

{$IFDEF FPC}
  {$MODE ObjFPC}
  {$MODESWITCH DuplicateLocals+}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, BaseUnix,
  AuxTypes, AuxClasses, NamedSharedItems;

{===============================================================================
    Library-specific exceptions
===============================================================================}

type
  ELSOException = class(Exception);

  ELSOSysInitError  = class(ELSOException);
  ELSOSysFinalError = class(ELSOException);
  ELSOSysOpError    = class(ELSOException);

  ELSOOpenError      = class(ELSOException);
  ELSInvalidLockType = class(ELSOException);
  ELSInvalidObject   = class(ELSOException);

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
    procedure InitializeLock; virtual; abstract;
    procedure FinalizeLock; virtual; abstract;
    // object initialization/finalization
    procedure Initialize(const Name: String); virtual;
    procedure Finalize; virtual;
  public
    constructor Create(const Name: String); overload; virtual;
    constructor Create; overload; virtual;
    constructor Open(const Name: String{$IFNDEF FPC}; Dummy: Integer = 0{$ENDIF}); virtual;
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
    procedure InitializeLock; override;
    procedure FinalizeLock; override;
  public
    Function TimedLockMutex(Timeout: UInt32): TLSOWaitResult; virtual;
    procedure LockMutex; virtual;
    Function TryLockMutex: Boolean; virtual;
    procedure UnlockMutex; virtual;
    Function LockMutexSilent: Boolean; virtual;
    Function TryLockMutexSilent: Boolean; virtual;
    Function UnlockMutexSilent: Boolean; virtual;
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

threadvar
  ThrErrorCode: cInt;

Function CheckErr(ErrorCode: cInt): Boolean;
begin
Result := ErrorCode = 0;
If Result then
  ThrErrorCode := 0
else
  ThrErrorCode := ErrorCode;
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
If CheckErr(pthread_mutexattr_init(@MutexAttr)) then
  try
    If not CheckErr(pthread_mutexattr_settype(@MutexAttr,PTHREAD_MUTEX_RECURSIVE)) then
      raise ELSOSysOpError.CreateFmt('TCriticalSection.Initialize: ' +
        'Failed to set mutex attribute TYPE (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckErr(pthread_mutex_init(@fMutex,@MutexAttr)) then
      raise ELSOSysInitError.CreateFmt('TCriticalSection.Initialize: ' +
        'Failed to initialize mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckErr(pthread_mutexattr_destroy(@MutexAttr)) then
      raise ELSOSysFinalError.CreateFmt('TCriticalSection.Initialize: ' +
        'Failed to destroy mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TCriticalSection.Initialize: ' +
       'Failed to initialize mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

procedure TCriticalSection.Finalize;
begin
If not CheckErr(pthread_mutex_destroy(@fMutex)) then
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
var
  LockResult: cInt;
begin
LockResult := pthread_mutex_trylock(@fMutex);
If LockResult <> 0 then
  begin
    Result := False;
    If LockResult <> ESysEBUSY then
      raise ELSOSysOpError.CreateFmt('TCriticalSection.TryEnter: ' +
        'Failed to try-lock mutex (%d - %s).',[LockResult,StrError(LockResult)]);
  end
else Result := True;
end;

//------------------------------------------------------------------------------

procedure TCriticalSection.Enter;
begin
If not CheckErr(pthread_mutex_lock(@fMutex)) then
  raise ELSOSysOpError.CreateFmt('TCriticalSection.Enter: ' +
    'Failed to lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

procedure TCriticalSection.Leave;
begin
If not CheckErr(pthread_mutex_unlock(@fMutex)) then
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
      ltSemaphore:      (Semapthore:    sem_t);
      ltCondVar:        (CondVar:       pthread_cond_t);
      ltBarrier:        (Barrier:       pthread_barrier_t);
      ltRWLock:         (RWLock:        pthread_rwlock_t);
      ltSimpleEvent:    (SimpleEvent:   TLSOSimpleEvent);
      ltAdvancedEVent:  (AdvancedEvent: TLSOAdvancedEvent)
  end;
  PLSOSharedData = ^TLSOSharedData;

//------------------------------------------------------------------------------

procedure ResolveTimeout(Timeout: UInt32; out TimeSpec: timespec);
begin
If clock_gettime(CLOCK_REALTIME,@TimeSpec) <> 0 then
  ELSOSysOpError.CreateFmt('ResolveTimeout: Failed to obtain current time (%d).',[errno]);
TimeSpec.tv_sec := TimeSpec.tv_sec + time_t(Timeout div 1000);
TimeSpec.tv_nsec := TimeSpec.tv_nsec + clong((Timeout mod 1000) * 1000000);
If TimeSpec.tv_nsec > 1000000000 then
  begin
    Inc(TimeSpec.tv_sec);
    TimeSpec.tv_nsec := TimeSpec.tv_nsec - 1000000000;
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
      raise ELSInvalidLockType.CreateFmt('TLinSyncObject.CheckAndSetLockType: ' +
        'Existing lock is of incompatible type (%d)',[Ord(PLSOSharedData(fSharedData)^.LockType)]);
  end
else PLSOSharedData(fSharedData)^.LockType := GetLockType;
end;

//------------------------------------------------------------------------------

procedure TLinSyncObject.Initialize(const Name: String);
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
        InitializeLock;
    finally
      fNamedSharedItem.GlobalUnlock;
    end;
  end
else
  begin
    fSharedData := AllocMem(SizeOf(TLSOSharedData));
    CheckAndSetLockType;
    InterlockedStore(PLSOSharedData(fSharedData)^.RefCount,1);
    InitializeLock;
  end;
ResolveLockPtr;
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

{-------------------------------------------------------------------------------
    TLinSyncObject - public methods
-------------------------------------------------------------------------------}

constructor TLinSyncObject.Create(const Name: String);
begin
inherited Create;
Initialize(Name);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TLinSyncObject.Create;
begin
Create('');
end;

//------------------------------------------------------------------------------

constructor TLinSyncObject.Open(const Name: String{$IFNDEF FPC}; Dummy: Integer = 0{$ENDIF});
begin
inherited Create;
If Length(Name) > 0 then
  Initialize(Name)
else
  raise ELSOOpenError.Create('TLinSyncObject.Open: Cannot open unnamed object.');
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
        else raise ELSInvalidObject.Create('TLinSyncObject.DuplicateFrom: Source object is in an inconsistent state.');
      end
    else Initialize(SourceObject.Name);
  end
else raise ELSInvalidObject.CreateFmt('TLinSyncObject.DuplicateFrom: Incompatible source object (%s).',[SourceObject.ClassName]);
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

procedure TMutex.InitializeLock;
var
  MutexAttr:  pthread_mutexattr_t;
begin
If CheckErr(pthread_mutexattr_init(@MutexAttr)) then
  try
    If not CheckErr(pthread_mutexattr_settype(@MutexAttr,PTHREAD_MUTEX_RECURSIVE)) then
      raise ELSOSysOpError.CreateFmt('TMutex.InitializeLock: Failed to set mutex attribute TYPE (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If fProcessShared then
      If not CheckErr(pthread_mutexattr_setpshared(@MutexAttr,PTHREAD_PROCESS_SHARED)) then
        raise ELSOSysOpError.CreateFmt('TMutex.InitializeLock: Failed to set mutex attribute PSHARED (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckErr(pthread_mutex_init(Addr(PLSOSharedData(fSharedData)^.Mutex),@MutexAttr)) then
      raise ELSOSysInitError.CreateFmt('TMutex.InitializeLock: Failed to initialize mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckErr(pthread_mutexattr_destroy(@MutexAttr)) then
      raise ELSOSysFinalError.CreateFmt('TMutex.InitializeLock: Failed to destroy mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TMutex.InitializeLock: Failed to initialize mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

procedure TMutex.FinalizeLock;
begin
If not CheckErr(pthread_mutex_destroy(fLockPtr)) then
  raise ELSOSysFinalError.CreateFmt('TMutex.FinalizeLock: Failed to destroy mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TMutex - public methods
-------------------------------------------------------------------------------}

Function TMutex.TimedLockMutex(Timeout: UInt32): TLSOWaitResult;
var
  TimeoutSpec:  timespec;
  LockResult:   cInt;
begin
ResolveTimeout(Timeout,TimeoutSpec);
LockResult := pthread_mutex_timedlock(fLockPtr,@TimeoutSpec);
fLastError:= Integer(LockResult);
case LockResult of
  0:              Result := wrSignaled;
  ESysETIMEDOUT:  Result := wrTimeout;
else
  Result := wrError;
end;
end;

//------------------------------------------------------------------------------

procedure TMutex.LockMutex;
begin
If not CheckErr(pthread_mutex_lock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TMutex.LockMutex: Failed to lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TMutex.TryLockMutex: Boolean;
var
  LockResult: cInt;
begin
LockResult := pthread_mutex_trylock(fLockPtr);
If LockResult <> 0 then
  begin
    Result := False;
    fLastError := Integer(LockResult);
    If LockResult <> ESysEBUSY then
      raise ELSOSysOpError.CreateFmt('TMutex.TryLockMutex: Failed to try-lock mutex (%d - %s).',[LockResult,StrError(LockResult)]);
  end
else Result := True;
end;

//------------------------------------------------------------------------------

procedure TMutex.UnlockMutex;
begin
If not CheckErr(pthread_mutex_unlock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TMutex.UnlockMutex: Failed to unlock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TMutex.LockMutexSilent: Boolean;
begin
Result := CheckErr(pthread_mutex_lock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TMutex.TryLockMutexSilent: Boolean;
begin
Result := CheckErr(pthread_mutex_trylock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TMutex.UnlockMutexSilent: Boolean;
begin
Result := CheckErr(pthread_mutex_unlock(fLockPtr));
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

