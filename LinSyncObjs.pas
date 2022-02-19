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
  SysUtils, BaseUnix, PThreads,
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
const
  INFINITE = UInt32($FFFFFFFF); // infinite timeout

type
  TLSOSharedUserData = packed array[0..31] of Byte;
  PLSOSharedUserData = ^TLSOSharedUserData;

type
  TLSOWaitResult = (wrSignaled,wrTimeout,wrError);

  TLSOLockType = (ltInvalid,ltSpinLock,ltEvent,ltMutex,ltSemaphore,ltRWLock,
                  ltCondVar,ltCondVarEx,ltBarrier,ltSimpleEvent,ltAdvancedEVent);

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
  TWrapperLinSyncObject = class(TLinSyncObject);

{===============================================================================
--------------------------------------------------------------------------------
                            TImplementorLinSynObject
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TImplementorLinSynObject - class declaration
===============================================================================}
type
  TImplementorLinSyncObject = class(TLinSyncObject);

{===============================================================================
--------------------------------------------------------------------------------
                                    TSpinLock
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSpinLock - class declaration
===============================================================================}
type
  TSpinLock = class(TWrapperLinSyncObject)
  protected
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
  public
    procedure LockStrict; virtual;
    Function Lock: Boolean; virtual;
    Function TryLockStrict: Boolean; virtual;
    Function TryLock: Boolean; virtual;
    procedure UnlockStrict; virtual;
    Function Unlock: Boolean; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                     TMutex
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TMutex - class declaration
===============================================================================}
type
  TMutex = class(TWrapperLinSyncObject)
  protected
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
  public
    procedure LockStrict; virtual;
    Function Lock: Boolean; virtual;
    Function TryLockStrict: Boolean; virtual;
    Function TryLock: Boolean; virtual;
    Function TimedLock(Timeout: UInt32): TLSOWaitResult; virtual;
    procedure UnlockStrict; virtual;
    Function Unlock: Boolean; virtual;
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
  TSemaphore = class(TWrapperLinSyncObject)
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
    Function GetValueStrict: cInt; virtual;
    Function GetValue: cInt; virtual;
    procedure WaitStrict; virtual;
    Function Wait: Boolean; virtual;
    Function TryWaitStrict: Boolean; virtual;
    Function TryWait: Boolean; virtual;
    Function TimedWait(Timeout: UInt32): TLSOWaitResult; virtual;
    procedure PostStrict; virtual;
    Function Post: Boolean; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                 TReadWriteLock
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TReadWriteLock - class declaration
===============================================================================}
type
  TReadWriteLock = class(TWrapperLinSyncObject)
  protected
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
  public
    procedure ReadLockStrict; virtual;
    Function ReadLock: Boolean; virtual;
    Function TryReadLockStrict: Boolean; virtual;
    Function TryReadLock: Boolean; virtual;
    Function TimedReadLock(Timeout: UInt32): TLSOWaitResult; virtual;
    procedure WriteLockStrict; virtual;
    Function WriteLock: Boolean virtual;
    Function TryWriteLockStrict: Boolean; virtual;
    Function TryWriteLock: Boolean; virtual;
    Function TimedWriteLock(Timeout: UInt32): TLSOWaitResult; virtual;
    procedure UnlockStrict; virtual;  // there is no read- or write-specific unlock
    Function Unlock: Boolean; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                               TConditionVariable
--------------------------------------------------------------------------------
===============================================================================}
type
  // types for autocycle
  TLSOWakeOption = (woWakeOne,woWakeAll,woWakeBeforeUnlock);
  TLSOWakeOptions = set of TLSOWakeOption;

  TLSOPredicateCheckEvent = procedure(Sender: TObject; var Predicate: Boolean) of object;
  TLSOPredicateCheckCallback = procedure(Sender: TObject; var Predicate: Boolean);

  TLSODataAccessEvent = procedure(Sender: TObject; var WakeOptions: TLSOWakeOptions) of object;
  TLSODataAccessCallback = procedure(Sender: TObject; var WakeOptions: TLSOWakeOptions);

{===============================================================================
    TConditionVariable - class declaration
===============================================================================}
type
  TConditionVariable = class(TWrapperLinSyncObject)
  protected
    // autocycle events
    fOnPredicateCheckEvent:     TLSOPredicateCheckEvent;
    fOnPredicateCheckCallback:  TLSOPredicateCheckCallback;
    fOnDataAccessEvent:         TLSODataAccessEvent;
    fOnDataAccessCallback:      TLSODataAccessCallback;
    // autocycle methods
    Function DoOnPredicateCheck: Boolean; virtual;
    Function DoOnDataAccess: TLSOWakeOptions; virtual;
    procedure SelectWake(WakeOptions: TLSOWakeOptions); virtual;
    // inherited methods
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
  public
    procedure WaitStrict(DataLock: ppthread_mutex_t); overload; virtual;
    procedure WaitStrict(DataLock: TMutex); overload; virtual;
    Function Wait(DataLock: ppthread_mutex_t): Boolean; overload; virtual;
    Function Wait(DataLock: TMutex): Boolean; overload; virtual;
    Function TimedWait(DataLock: ppthread_mutex_t; Timeout: UInt32): TLSOWaitResult; overload; virtual;
    Function TimedWait(DataLock: TMutex; Timeout: UInt32): TLSOWaitResult; overload; virtual;
    procedure SignalStrict; virtual;
    Function Signal: Boolean; virtual;
    procedure BroadcastStrict; virtual;
    Function Broadcast: Boolean; virtual;
    procedure AutoCycle(DataLock: ppthread_mutex_t; Timeout: UInt32); overload; virtual;
    procedure AutoCycle(DataLock: TMutex; Timeout: UInt32); overload; virtual;
    procedure AutoCycle(DataLock: ppthread_mutex_t); overload; virtual;
    procedure AutoCycle(DataLock: TMutex); overload; virtual;
    // events
    property OnPredicateCheckEvent: TLSOPredicateCheckEvent read fOnPredicateCheckEvent write fOnPredicateCheckEvent;
    property OnPredicateCheckCallback: TLSOPredicateCheckCallback read fOnPredicateCheckCallback write fOnPredicateCheckCallback;
    property OnPredicateCheck: TLSOPredicateCheckEvent read fOnPredicateCheckEvent write fOnPredicateCheckEvent;
    property OnDataAccessEvent: TLSODataAccessEvent read fOnDataAccessEvent write fOnDataAccessEvent;
    property OnDataAccessCallback: TLSODataAccessCallback read fOnDataAccessCallback write fOnDataAccessCallback;
    property OnDataAccess: TLSODataAccessEvent read fOnDataAccessEvent write fOnDataAccessEvent;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                              TConditionVariableEx
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TConditionVariableEx - class declaration
===============================================================================}
type
  TConditionVariableEx = class(TConditionVariable)
  protected
    fDataLockPtr: Pointer;
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
  public
    procedure LockStrict; virtual;
    Function Lock: Boolean; virtual;
    procedure UnlockStrict; virtual;
    Function Unlock: Boolean; virtual;
    procedure WaitStrict; overload; virtual;
    Function Wait: Boolean; overload; virtual;
    Function TimedWait(Timeout: UInt32): TLSOWaitResult; overload; virtual;
    procedure AutoCycle(Timeout: UInt32); overload; virtual;
    procedure AutoCycle; overload; virtual;
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
  UnixType, Linux, Errors,
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

type
  TLSOEvent = record
  end;

type
  TLSOAdvancedEvent = record
  end;

type
  TLSOConditionVariableEx = record
    DataLock: pthread_mutex_t;
    CondVar:  pthread_cond_t;
  end;

type
  TLSOSharedData = record
    SharedUserData: TLSOSharedUserData;
    RefCount:       Int32;
    case LockType: TLSOLockType of
      ltSpinLock:       (SpinLock:      pthread_spinlock_t);
      ltSimpleEvent:    (SimpleEvent:   TLSOSimpleEvent);
      ltEvent:          (Event:         TLSOEvent);
      ltAdvancedEVent:  (AdvancedEvent: TLSOAdvancedEvent);
      ltMutex:          (Mutex:         pthread_mutex_t);
      ltSemaphore:      (Semaphore:     sem_t);
      ltRWLock:         (RWLock:        pthread_rwlock_t);
      ltCondVar:        (CondVar:       pthread_cond_t);
      ltCondVarEx:      (CondVarEx:     TLSOConditionVariableEx);
      ltBarrier:        (Barrier:       pthread_barrier_t);
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
        'Existing lock is of incompatible type (%d).',[Ord(PLSOSharedData(fSharedData)^.LockType)]);
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
                                    TSpinLock
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSpinLock - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TSpinLock - protected methods
-------------------------------------------------------------------------------}

class Function TSpinLock.GetLockType: TLSOLockType;
begin
Result := ltSpinLock;
end;

//------------------------------------------------------------------------------

procedure TSpinLock.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.SpinLock);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
procedure TSpinLock.InitializeLock(InitializingData: PtrUInt);
var
  ProcShared: cInt;
begin
If fProcessShared then
  ProcShared := PTHREAD_PROCESS_SHARED
else
  ProcShared := PTHREAD_PROCESS_PRIVATE;
If not CheckResErr(pthread_spin_init(Addr(PLSOSharedData(fSharedData)^.SpinLock),ProcShared)) then
  raise ELSOSysInitError.CreateFmt('TSpinLock.InitializeLock: ' +
    'Failed to initialize spinlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TSpinLock.FinalizeLock;
begin
If not CheckResErr(pthread_spin_destroy(Addr(PLSOSharedData(fSharedData)^.SpinLock))) then
  raise ELSOSysFinalError.CreateFmt('TSpinLock.FinalizeLock: ' +
    'Failed to destroy spinlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TSpinLock - public methods
-------------------------------------------------------------------------------}

procedure TSpinLock.LockStrict;
begin
If not CheckResErr(pthread_spin_lock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TSpinLock.LockStrict: ' +
    'Failed to lock spinlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TSpinLock.Lock: Boolean;
begin
Result := CheckResErr(pthread_spin_lock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TSpinLock.TryLockStrict: Boolean;
begin
Result := CheckResErr(pthread_spin_trylock(fLockPtr));
If not Result and (ThrErrorCode <> ESysEBUSY) then
  raise ELSOSysOpError.CreateFmt('TSpinLock.TryLockStrict: ' +
    'Failed to try-lock spinlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TSpinLock.TryLock: Boolean;
begin
Result := CheckResErr(pthread_spin_trylock(fLockPtr));
If not Result and (ThrErrorCode = ESysEBUSY) then
  fLastError := 0
else
  fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

procedure TSpinLock.UnlockStrict;
begin
If not CheckResErr(pthread_spin_unlock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TSpinLock.UnlockStrict: ' +
    'Failed to unlock spinlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TSpinLock.Unlock: Boolean;
begin
Result := CheckResErr(pthread_spin_unlock(fLockPtr));
fLastError := Integer(ThrErrorCode);
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

procedure TMutex.LockStrict;
begin
If not CheckResErr(pthread_mutex_lock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TMutex.LockStrict: ' +
    'Failed to lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TMutex.Lock: Boolean;
begin
Result := CheckResErr(pthread_mutex_lock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TMutex.TryLockStrict: Boolean;
begin
Result := CheckResErr(pthread_mutex_trylock(fLockPtr));
If not Result and (ThrErrorCode <> ESysEBUSY) then
  raise ELSOSysOpError.CreateFmt('TMutex.TryLockStrict: ' +
    'Failed to try-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TMutex.TryLock: Boolean;
begin
Result := CheckResErr(pthread_mutex_trylock(fLockPtr));
If not Result and (ThrErrorCode = ESysEBUSY) then
  fLastError := 0
else
  fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TMutex.TimedLock(Timeout: UInt32): TLSOWaitResult;
var
  TimeoutSpec:  timespec;
begin
If Timeout <> INFINITE then
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
  end
else
  begin
    If Lock then
      Result := wrSignaled
    else
      Result := wrError;
  end;
end;

//------------------------------------------------------------------------------

procedure TMutex.UnlockStrict;
begin
If not CheckResErr(pthread_mutex_unlock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TMutex.UnlockStrict: ' +
    'Failed to unlock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TMutex.Unlock: Boolean;
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

Function TSemaphore.GetValueStrict: cInt;
begin
If not CheckErrAlt(sem_getvalue(fLockPtr,@Result)) then
  raise ELSOSysOpError.CreateFmt('TSemaphore.GetValueStrict: ' +
    'Failed to get  semaphore value (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TSemaphore.GetValue: cInt;
begin
If not CheckErrAlt(sem_getvalue(fLockPtr,@Result)) then
  begin
    fLastError := ThrErrorCode;
    Result := -1;
  end;
end;

//------------------------------------------------------------------------------

procedure TSemaphore.WaitStrict;
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
        raise ELSOSysOpError.CreateFmt('TSemaphore.WaitStrict: ' +
          'Failed to wait on semaphore (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    end;
until ExitWait;
end;

//------------------------------------------------------------------------------

Function TSemaphore.Wait: Boolean;
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

Function TSemaphore.TryWaitStrict: Boolean;
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
      raise ELSOSysOpError.CreateFmt('TSemaphore.TryWaitStrict: ' +
        'Failed to try-wait on semaphore (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    end;
until ExitWait;
end;

//------------------------------------------------------------------------------

Function TSemaphore.TryWait: Boolean;
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

Function TSemaphore.TimedWait(Timeout: UInt32): TLSOWaitResult;
var
  TimeoutSpec:  timespec;
  ExitWait:     Boolean;
begin
If Timeout <> INFINITE then
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
  end
else
  begin
    If Wait then
      Result := wrSignaled
    else
      Result := wrError;
  end;
end;

//------------------------------------------------------------------------------

procedure TSemaphore.PostStrict;
begin
If not CheckErrAlt(sem_post(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TSemaphore.PostStrict: ' +
    'Failed to post semaphore (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TSemaphore.Post: Boolean;
begin
Result := CheckErrAlt(sem_post(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;


{===============================================================================
--------------------------------------------------------------------------------
                                 TReadWriteLock
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TReadWriteLock - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TReadWriteLock - protected methods
-------------------------------------------------------------------------------}

class Function TReadWriteLock.GetLockType: TLSOLockType;
begin
Result := ltRWLock;
end;

//------------------------------------------------------------------------------

procedure TReadWriteLock.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.RWLock);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
procedure TReadWriteLock.InitializeLock(InitializingData: PtrUInt);
var
  RWLockAttr: pthread_rwlockattr_t;
begin
If CheckResErr(pthread_rwlockattr_init(@RWLockAttr)) then
  try
    If fProcessShared then
      If not CheckResErr(pthread_rwlockattr_setpshared(@RWLockAttr,PTHREAD_PROCESS_SHARED)) then
        raise ELSOSysOpError.CreateFmt('TReadWriteLock.InitializeLock: ' +
          'Failed to set rwlock attribute PSHARED (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckResErr(pthread_rwlock_init(Addr(PLSOSharedData(fSharedData)^.RWLock),@RWLockAttr)) then
      raise ELSOSysInitError.CreateFmt('TReadWriteLock.InitializeLock: ' +
        'Failed to initialize rwlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckResErr(pthread_rwlockattr_destroy(@RWLockAttr)) then
      raise ELSOSysFinalError.CreateFmt('TReadWriteLock.InitializeLock: ' +
        'Failed to destroy rwlock attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TReadWriteLock.InitializeLock: ' +
       'Failed to initialize rwlock attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TReadWriteLock.FinalizeLock;
begin
If not CheckResErr(pthread_rwlock_destroy(Addr(PLSOSharedData(fSharedData)^.RWLock))) then
  raise ELSOSysFinalError.CreateFmt('TReadWriteLock.FinalizeLock: ' +
    'Failed to destroy rwlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TReadWriteLock - public methods
-------------------------------------------------------------------------------}

procedure TReadWriteLock.ReadLockStrict;
begin
If not CheckResErr(pthread_rwlock_rdlock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TReadWriteLock.ReadLockStrict: ' +
    'Failed to read-lock rwlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.ReadLock: Boolean;
begin
Result := CheckResErr(pthread_rwlock_rdlock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.TryReadLockStrict: Boolean;
begin
Result := CheckResErr(pthread_rwlock_tryrdlock(fLockPtr));
If not Result and (ThrErrorCode <> ESysEBUSY) then
  raise ELSOSysOpError.CreateFmt('TReadWriteLock.TryReadLockStrict: ' +
    'Failed to try-read-lock rwlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.TryReadLock: Boolean;
begin
Result := CheckResErr(pthread_rwlock_tryrdlock(fLockPtr));
If not Result and (ThrErrorCode = ESysEBUSY) then
  fLastError := 0
else
  fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.TimedReadLock(Timeout: UInt32): TLSOWaitResult;
var
  TimeoutSpec:  timespec;
begin
If Timeout <> INFINITE then
  begin
    ResolveTimeout(Timeout,TimeoutSpec);
    If not CheckResErr(pthread_rwlock_timedrdlock(fLockPtr,@TimeoutSpec)) then
      begin
        If ThrErrorCode <> ESysETIMEDOUT then
          begin
            Result := wrError;
            fLastError := Integer(ThrErrorCode);
          end
        else Result := wrTimeout;
      end
    else Result := wrSignaled;
  end
else
  begin
    If ReadLock then
      Result := wrSignaled
    else
      Result := wrError;
  end;
end;
//------------------------------------------------------------------------------

procedure TReadWriteLock.WriteLockStrict;
begin
If not CheckResErr(pthread_rwlock_wrlock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TReadWriteLock.WriteLockStrict: ' +
    'Failed to write-lock rwlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.WriteLock: Boolean;
begin
Result := CheckResErr(pthread_rwlock_wrlock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.TryWriteLockStrict: Boolean;
begin
Result := CheckResErr(pthread_rwlock_trywrlock(fLockPtr));
If not Result and (ThrErrorCode <> ESysEBUSY) then
  raise ELSOSysOpError.CreateFmt('TReadWriteLock.TryWriteLockStrict: ' +
    'Failed to try-write-lock rwlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.TryWriteLock: Boolean;
begin
Result := CheckResErr(pthread_rwlock_trywrlock(fLockPtr));
If not Result and (ThrErrorCode = ESysEBUSY) then
  fLastError := 0
else
  fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.TimedWriteLock(Timeout: UInt32): TLSOWaitResult;
var
  TimeoutSpec:  timespec;
begin
If Timeout <> INFINITE then
  begin
    ResolveTimeout(Timeout,TimeoutSpec);
    If not CheckResErr(pthread_rwlock_timedwrlock(fLockPtr,@TimeoutSpec)) then
      begin
        If ThrErrorCode <> ESysETIMEDOUT then
          begin
            Result := wrError;
            fLastError := Integer(ThrErrorCode);
          end
        else Result := wrTimeout;
      end
    else Result := wrSignaled;
  end
else
  begin
    If WriteLock then
      Result := wrSignaled
    else
      Result := wrError;
  end;
end;

//------------------------------------------------------------------------------

procedure TReadWriteLock.UnlockStrict;
begin
If not CheckResErr(pthread_rwlock_unlock(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TReadWriteLock.UnlockStrict: ' +
    'Failed to unlock rwlock (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TReadWriteLock.Unlock: Boolean;
begin
Result := CheckResErr(pthread_rwlock_unlock(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;


{===============================================================================
--------------------------------------------------------------------------------
                               TConditionVariable
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TConditionVariable - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TConditionVariable - protected methods
-------------------------------------------------------------------------------}

Function TConditionVariable.DoOnPredicateCheck: Boolean;
begin
Result := False;
If Assigned(fOnPredicateCheckEvent) then
  fOnPredicateCheckEvent(Self,Result);
If Assigned(fOnPredicateCheckCallback) then
  fOnPredicateCheckCallback(Self,Result);
end;

//------------------------------------------------------------------------------

Function TConditionVariable.DoOnDataAccess: TLSOWakeOptions;
begin
If Assigned(fOnDataAccessEvent) or Assigned(fOnDataAccessCallback) then
  begin
    Result := [];
    If Assigned(fOnDataAccessEvent) then
      fOnDataAccessEvent(Self,Result);
    If Assigned(fOnDataAccessCallback) then
      fOnDataAccessCallback(Self,Result);
  end
else Result := [woWakeAll];
end;

//------------------------------------------------------------------------------

procedure TConditionVariable.SelectWake(WakeOptions: TLSOWakeOptions);
begin
If ([woWakeOne,woWakeAll] *{intersection} WakeOptions) <> [] then
  begin
    If woWakeAll in WakeOptions then
      Broadcast
    else
      Signal;
  end;
end;

//------------------------------------------------------------------------------

class Function TConditionVariable.GetLockType: TLSOLockType;
begin
Result := ltCondVar;
end;

//------------------------------------------------------------------------------

procedure TConditionVariable.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.CondVar);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
procedure TConditionVariable.InitializeLock(InitializingData: PtrUInt);
var
  CondVarAttr:  pthread_condattr_t;
begin
If CheckResErr(pthread_condattr_init(@CondVarAttr)) then
  try
    If fProcessShared then
      If not CheckResErr(pthread_condattr_setpshared(@CondVarAttr,PTHREAD_PROCESS_SHARED)) then
        raise ELSOSysOpError.CreateFmt('TConditionVariable.InitializeLock: ' +
          'Failed to set condvar attribute PSHARED (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckResErr(pthread_cond_init(Addr(PLSOSharedData(fSharedData)^.CondVar),@CondVarAttr)) then
      raise ELSOSysInitError.CreateFmt('TConditionVariable.InitializeLock: ' +
        'Failed to initialize condvar (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckResErr(pthread_condattr_destroy(@CondVarAttr)) then
      raise ELSOSysFinalError.CreateFmt('TConditionVariable.InitializeLock: ' +
        'Failed to destroy condvar attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TConditionVariable.InitializeLock: ' +
       'Failed to initialize condvar attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TConditionVariable.FinalizeLock;
begin
If not CheckResErr(pthread_cond_destroy(Addr(PLSOSharedData(fSharedData)^.CondVar))) then
  raise ELSOSysFinalError.CreateFmt('TConditionVariable.FinalizeLock: ' +
    'Failed to destroy condvar (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TConditionVariable - public methods
-------------------------------------------------------------------------------}

procedure TConditionVariable.WaitStrict(DataLock: ppthread_mutex_t);
begin
If not CheckResErr(pthread_cond_wait(fLockPtr,DataLock)) then
  raise ELSOSysOpError.CreateFmt('TConditionVariable.WaitStrict: ' +
    'Failed to wait on condvar (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

procedure TConditionVariable.WaitStrict(DataLock: TMutex);
begin
WaitStrict(DataLock.fLockPtr);
end;

//------------------------------------------------------------------------------

Function TConditionVariable.Wait(DataLock: ppthread_mutex_t): Boolean;
begin
Result := CheckResErr(pthread_cond_wait(fLockPtr,DataLock));
fLastError := Integer(ThrErrorCode);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function TConditionVariable.Wait(DataLock: TMutex): Boolean;
begin
Result := Wait(DataLock.fLockPtr);
end;

//------------------------------------------------------------------------------

Function TConditionVariable.TimedWait(DataLock: ppthread_mutex_t; Timeout: UInt32): TLSOWaitResult;
var
  TimeoutSpec:  timespec;
begin
If Timeout <> INFINITE then
  begin
    ResolveTimeout(Timeout,TimeoutSpec);
    If not CheckResErr(pthread_cond_timedwait(fLockPtr,DataLock,@TimeoutSpec)) then
      begin
        If ThrErrorCode <> ESysETIMEDOUT then
          begin
            Result := wrError;
            fLastError := Integer(ThrErrorCode);
          end
        else Result := wrTimeout;
      end
    else Result := wrSignaled;
  end
else
  begin
    If Wait(DataLock) then
      Result := wrSignaled
    else
      Result := wrError;
  end;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function TConditionVariable.TimedWait(DataLock: TMutex; Timeout: UInt32): TLSOWaitResult;
begin
Result := TimedWait(DataLock.fLockPtr,Timeout);
end;

//------------------------------------------------------------------------------

procedure TConditionVariable.SignalStrict;
begin
If not CheckResErr(pthread_cond_signal(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TConditionVariable.SignalStrict: ' +
    'Failed to signal condvar (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TConditionVariable.Signal: Boolean;
begin
Result := CheckResErr(pthread_cond_signal(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

procedure TConditionVariable.BroadcastStrict;
begin
If not CheckResErr(pthread_cond_broadcast(fLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TConditionVariable.BroadcastStrict: ' +
    'Failed to broadcast condvar (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TConditionVariable.Broadcast: Boolean;
begin
Result := CheckResErr(pthread_cond_broadcast(fLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

procedure TConditionVariable.AutoCycle(DataLock: ppthread_mutex_t; Timeout: UInt32);
var
  WakeOptions:  TLSOWakeOptions;
begin
If Assigned(fOnPredicateCheckEvent) or Assigned(fOnPredicateCheckCallback) then
  begin
    // lock synchronizer
    If not CheckResErr(pthread_mutex_lock(DataLock)) then
      raise ELSOSysOpError.CreateFmt('TConditionVariable.AutoCycle: ' +
        'Failed to lock data-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    // test predicate and wait condition
    while not DoOnPredicateCheck do
      TimedWait(DataLock,Timeout);
    // access protected data
    WakeOptions := DoOnDataAccess;
    // wake waiters before unlock
    If (woWakeBeforeUnlock in WakeOptions) then
      SelectWake(WakeOptions);
    // unlock synchronizer
    If not CheckResErr(pthread_mutex_unlock(DataLock)) then
      raise ELSOSysOpError.CreateFmt('TConditionVariable.AutoCycle: ' +
        'Failed to unlock data-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    // wake waiters after unlock
    If not(woWakeBeforeUnlock in WakeOptions) then
      SelectWake(WakeOptions);
  end;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

procedure TConditionVariable.AutoCycle(DataLock: TMutex; Timeout: UInt32);
var
  WakeOptions:  TLSOWakeOptions;
begin
If Assigned(fOnPredicateCheckEvent) or Assigned(fOnPredicateCheckCallback) then
  begin
    DataLock.LockStrict;
    while not DoOnPredicateCheck do
      TimedWait(DataLock,Timeout);
    WakeOptions := DoOnDataAccess;
    If (woWakeBeforeUnlock in WakeOptions) then
      SelectWake(WakeOptions);
    DataLock.UnlockStrict;
    If not(woWakeBeforeUnlock in WakeOptions) then
      SelectWake(WakeOptions);
  end;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

procedure TConditionVariable.AutoCycle(DataLock: ppthread_mutex_t);
begin
AutoCycle(DataLock,INFINITE);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

procedure TConditionVariable.AutoCycle(DataLock: TMutex);
begin
AutoCycle(DataLock,INFINITE);
end;

{===============================================================================
--------------------------------------------------------------------------------
                              TConditionVariableEx
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TConditionVariableEx - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TConditionVariableEx - protected methods
-------------------------------------------------------------------------------}

class Function TConditionVariableEx.GetLockType: TLSOLockType;
begin
Result := ltCondVarEx;
end;

//------------------------------------------------------------------------------

procedure TConditionVariableEx.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.CondVarEx.CondVar);
fDataLockPtr := Addr(PLSOSharedData(fSharedData)^.CondVarEx.DataLock);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
procedure TConditionVariableEx.InitializeLock(InitializingData: PtrUInt);
var
  MutexAttr:    pthread_mutexattr_t;
  CondVarAttr:  pthread_condattr_t;
begin
// data-lock mutex
If CheckResErr(pthread_mutexattr_init(@MutexAttr)) then
  try
    If not CheckResErr(pthread_mutexattr_settype(@MutexAttr,PTHREAD_MUTEX_RECURSIVE)) then
      raise ELSOSysOpError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
        'Failed to set data-lock mutex attribute TYPE (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If fProcessShared then
      If not CheckResErr(pthread_mutexattr_setpshared(@MutexAttr,PTHREAD_PROCESS_SHARED)) then
        raise ELSOSysOpError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
          'Failed to set data-lock mutex attribute PSHARED (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckResErr(pthread_mutex_init(Addr(PLSOSharedData(fSharedData)^.CondVarEx.DataLock),@MutexAttr)) then
      raise ELSOSysInitError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
        'Failed to initialize data-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckResErr(pthread_mutexattr_destroy(@MutexAttr)) then
      raise ELSOSysFinalError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
        'Failed to destroy data-lock mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
       'Failed to initialize data-lock mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
// condition variable
If CheckResErr(pthread_condattr_init(@CondVarAttr)) then
  try
    If fProcessShared then
      If not CheckResErr(pthread_condattr_setpshared(@CondVarAttr,PTHREAD_PROCESS_SHARED)) then
        raise ELSOSysOpError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
          'Failed to set condvar attribute PSHARED (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckResErr(pthread_cond_init(Addr(PLSOSharedData(fSharedData)^.CondVarEx.CondVar),@CondVarAttr)) then
      raise ELSOSysInitError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
        'Failed to initialize condvar (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckResErr(pthread_condattr_destroy(@CondVarAttr)) then
      raise ELSOSysFinalError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
        'Failed to destroy condvar attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
       'Failed to initialize condvar attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TConditionVariableEx.FinalizeLock;
begin
If not CheckResErr(pthread_cond_destroy(Addr(PLSOSharedData(fSharedData)^.CondVarEx.CondVar))) then
  raise ELSOSysFinalError.CreateFmt('TConditionVariableEx.FinalizeLock: ' +
    'Failed to destroy condvar (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
If not CheckResErr(pthread_mutex_destroy(Addr(PLSOSharedData(fSharedData)^.CondVarEx.DataLock))) then
  raise ELSOSysFinalError.CreateFmt('TConditionVariableEx.FinalizeLock: ' +
    'Failed to destroy data-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TConditionVariableEx - public methods
-------------------------------------------------------------------------------}

procedure TConditionVariableEx.LockStrict;
begin
If not CheckResErr(pthread_mutex_lock(fDataLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TConditionVariableEx.LockStrict: ' +
    'Failed to lock data-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TConditionVariableEx.Lock: Boolean;
begin
Result := CheckResErr(pthread_mutex_lock(fDataLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

procedure TConditionVariableEx.UnlockStrict;
begin
If not CheckResErr(pthread_mutex_unlock(fDataLockPtr)) then
  raise ELSOSysOpError.CreateFmt('TConditionVariableEx.UnlockStrict: ' +
    'Failed to unlock data-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TConditionVariableEx.Unlock: Boolean;
begin
Result := CheckResErr(pthread_mutex_unlock(fDataLockPtr));
fLastError := Integer(ThrErrorCode);
end;

//------------------------------------------------------------------------------

procedure TConditionVariableEx.WaitStrict;
begin
WaitStrict(fDataLockPtr);
end;

//------------------------------------------------------------------------------

Function TConditionVariableEx.Wait: Boolean;
begin
Result := Wait(fDataLockPtr);
end;

//------------------------------------------------------------------------------

Function TConditionVariableEx.TimedWait(Timeout: UInt32): TLSOWaitResult;
begin
Result := TimedWait(fDataLockPtr,Timeout);
end;

//------------------------------------------------------------------------------

procedure TConditionVariableEx.AutoCycle(Timeout: UInt32);
begin
AutoCycle(fDataLockPtr,Timeout);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

procedure TConditionVariableEx.AutoCycle;
begin
AutoCycle(fDataLockPtr,INFINITE);
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

