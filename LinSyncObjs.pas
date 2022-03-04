{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  LinSyncObjs

    This library provides a set of classes encapsulating synchronization
    objects available in pthread library for Linux operating system.
    It also implements some new and derived synchronization primitives that
    are not directly provided by pthread and a limited form of waiting for
    multiple synchronization objects (in this case waiting for multiple events).

    All provided objects, except for critical section, can be created either
    as thread-shared (can be used for synchronization between threads of single
    process) or as process-shared (synchronization between any threads within
    the system, even in different processes).

    Process-shared objects reside in a shared memory and are distinguished by
    their name (such object must have a non-empty name). All object types share
    the same name space, so it is not possible for multiple objects of different
    type to have the same name. Names are case sensitive.

  Version 1.0 alpha (2022-03-01) - requires extensive testing

  Last change 2022-03-04

  ©2022 František Milt

  Contacts:
    František Milt: frantisek.milt@gmail.com

  Support:
    If you find this code useful, please consider supporting its author(s) by
    making a small donation using the following link(s):

      https://www.paypal.me/FMilt

  Changelog:
    For detailed changelog and history please refer to this git repository:

      github.com/TheLazyTomcat/Lib.LinSyncObjs

  Dependencies:
    AuxTypes           - github.com/TheLazyTomcat/Lib.AuxTypes
    AuxClasses         - github.com/TheLazyTomcat/Lib.AuxClasses
    BitOps             - github.com/TheLazyTomcat/Lib.BitOps
    BitVector          - github.com/TheLazyTomcat/Lib.BitVector
    HashBase           - github.com/TheLazyTomcat/Lib.HashBase
    InterlockedOps     - github.com/TheLazyTomcat/Lib.InterlockedOps
    NamedSharedItems   - github.com/TheLazyTomcat/Lib.NamedSharedItems
    SHA1               - github.com/TheLazyTomcat/Lib.SHA1
    SimpleCPUID        - github.com/TheLazyTomcat/Lib.SimpleCPUID
    SimpleFutex        - github.com/TheLazyTomcat/Lib.SimpleFutex
    SharedMemoryStream - github.com/TheLazyTomcat/Lib.SharedMemoryStream
    StaticMemoryStream - github.com/TheLazyTomcat/Lib.StaticMemoryStream
    StrRect            - github.com/TheLazyTomcat/Lib.StrRect

===============================================================================}
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
  AuxTypes, AuxClasses, BitVector, SimpleFutex, SharedMemoryStream,
  NamedSharedItems;

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

  ELSOFutexOpError = class(ELSOException);

  ELSOMultiWaitError   = class(ELSOException);
  ELSOIndexOutOfBounds = class(ELSOException);

{===============================================================================
--------------------------------------------------------------------------------
                                TCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{
  To use the TCriticalSection object, create one instance and then pass this
  one instance to other threads that need to be synchronized.

  Make sure to only free the object once.

  You can also set the property FreeOnRelease to true (by default false) and
  then use the build-in reference counting - call method Acquire for each
  thread using the object (including the one that created it) and method
  Release every time a thread will stop using it. When reference count reaches
  zero in a call to Release, the object will be automatically freed within that
  call.
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
{
  To properly use linux synchronization object based on TLinSyncObject class
  (all that are currently provided), create an instance and use this one
  instance only in a thread where it was created.

  To access the object in other threads of the same process, create a new
  instance using DuplicateFrom constructor, passing the progenitor instance or
  any duplicate instance created previously from it as a source.
  You can also use Open or Create constructors when the object is created as
  process-shared.
  It is possible and permissible to use the same instance in multiple threads
  of single process, but this practice is highly discouraged as the object
  fields are not protected against concurrent access (affects eg. LastError
  property).

  To access the object in a different process (object must be created as
  process-shared), use Open or Create constructors using the same name as was
  used for the first instance. When opening process-shared object in the same
  process where it was created or already opened, you can use DuplicateFrom
  constructor.

  Most public functions of classes derived from TLinSyncObject that are
  operating on the object state are provided in two versions - as strict and
  non-strict.
  Unless noted otherwise, the strict functions will raise an ELSOSysOpError
  exception when the internal operation fails. Non-strict functions indicate
  success or failure via their result (true = success, false = failure).

  Value stored in LastError property is undefined after a call to any strict
  function.
  When non-strict function succeeds, the value of LastError is also undefined.
  When it fails, the LastError will contain a code of system error that caused
  the function to fail.

  Non-strict function beginning with a "Try" (eg. TryLock) might return false
  even when it technically succeeded in its operation (the object was already
  locked). In that case, LastError is set to 0.

  Timed functions will never raise an exception, all errors are indicated by
  returning wrError result.
}
{===============================================================================
    TLinSyncObject - public types and constants
===============================================================================}
const
  INFINITE = UInt32($FFFFFFFF); // infinite timeout

type
  TLSOSharedUserData = packed array[0..31] of Byte;
  PLSOSharedUserData = ^TLSOSharedUserData;

type
  TLSOWaitResult = (wrSignaled,wrTimeout,wrError);

  TLSOLockType = (ltInvalid,ltSpinLock,ltSimpleManualEvent,ltSimpleAutoEvent,
                  ltEvent,ltAdvancedEvent,ltMutex,ltSemaphore,ltRWLock,
                  ltCondVar,ltCondVarEx,ltBarrier);

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
  public
    constructor ProtectedCreate(const Name: String; InitializingData: PtrUInt); virtual;
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
{
  TWrapperLinSyncObject serves as a base class for objects that are directly
  wrapping a pthread-provided synchronization primitive.
}
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
{
  TImplementorLinSyncObject is a base class for objects creating a distinct
  synchronization primitive that is more than a simple wrapper for pthread
  primitives.
}
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
                                TSimpleEventBase
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSimpleEventBase - class declaration
===============================================================================}
type
  TSimpleEventBase = class(TImplementorLinSyncObject)
  protected
    procedure FinalizeLock; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
  public
    // LockStrict will never raise an exception
    procedure LockStrict; virtual;
    // Lock always succeeds
    Function Lock: Boolean; virtual;
    procedure UnlockStrict; virtual;
    // Unlock sets LastError to -1 in case of any failure
    Function Unlock: Boolean; virtual;
    procedure WaitStrict; virtual; abstract;
    Function Wait: Boolean; virtual; abstract;
    Function TryWaitStrict: Boolean; virtual; abstract;
    Function TryWait: Boolean; virtual; abstract;
    Function TimedWait(Timeout: UInt32): TLSOWaitResult; virtual; abstract;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                               TSimpleManualEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSimpleManualEvent - class declaration
===============================================================================}
type
  TSimpleManualEvent = class(TSimpleEventBase)
  protected
    class Function GetLockType: TLSOLockType; override;
  public
    procedure WaitStrict; override;
    // Wait sets LastError to -1 in case of any failure
    Function Wait: Boolean; override;
    // TryWaitStrict will never raise an exception
    Function TryWaitStrict: Boolean; override;
    Function TryWait: Boolean; override;
    Function TimedWait(Timeout: UInt32): TLSOWaitResult; override;
  end;

  TSimpleEvent = TSimpleManualEvent;

{===============================================================================
--------------------------------------------------------------------------------
                                TSimpleAutoEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSimpleAutoEvent - class declaration
===============================================================================}
type
  TSimpleAutoEvent = class(TSimpleEventBase)
  protected
    class Function GetLockType: TLSOLockType; override;
  public
    procedure WaitStrict; override;
    // Wait sets LastError to -1 in case of any failure
    Function Wait: Boolean; override;
    // TryWaitStrict will never raise an exception
    Function TryWaitStrict: Boolean; override;
    Function TryWait: Boolean; override;
    Function TimedWait(Timeout: UInt32): TLSOWaitResult; override;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                     TEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TEvent - class declaration
===============================================================================}
type
  TEvent = class(TImplementorLinSyncObject)
  protected
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
    procedure LockData; virtual;
    procedure UnlockData; virtual;
    // multi-wait methods
    procedure WasLocked; virtual;
    procedure WasUnlocked; virtual;
  public
    constructor Create(const Name: String; ManualReset,InitialState: Boolean); overload; virtual;
    constructor Create(ManualReset,InitialState: Boolean); overload; virtual;
    constructor Create(const Name: String); override; // ManualReset := True, InitialState := False
    constructor Create; override;
    procedure LockStrict; virtual;
  {
    Lock sets LastError to -1 in case of any failure.
    Can raise an exception if internal data lock fails.
  }
    Function Lock: Boolean; virtual;
    procedure UnlockStrict; virtual;
  {
    Unlock sets LastError to -1 in case of any failure.
    Can raise an exception if internal data lock fails.
  }
    Function Unlock: Boolean; virtual;
    procedure WaitStrict; virtual;
  {
    Wait sets LastError to -1 in case of any failure.
    Can raise an exception if internal data lock fails.
  }
    Function Wait: Boolean; virtual;
    Function TryWaitStrict: Boolean; virtual;
  {
    TryWait sets LastError to -1 in case of any failure.
    Can raise an exception if internal data lock fails.
  }
    Function TryWait: Boolean; virtual;
    // TimedWait can raise an exception if internal data lock fails.
    Function TimedWait(Timeout: UInt32): TLSOWaitResult; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                               TLSOMultiWaitSlots
--------------------------------------------------------------------------------
===============================================================================}
type
  TLSOMultiWaitSlotIndex = Int16;

{===============================================================================
    TLSOMultiWaitSlots - class declaration
===============================================================================}
type
  TLSOMultiWaitSlots = class(TSharedMemory)
  protected
    fSlotCount:   Integer;
    fSlotMap:     TBitVector;
    fSlotMemory:  Pointer;
    Function GetSlot(SlotIndex: TLSOMultiWaitSlotIndex): PFutex; virtual;
    procedure Initialize; override;
    procedure Finalize; override;
  public
    constructor Create;
    Function GetFreeSlotIndex(out SlotIndex: TLSOMultiWaitSlotIndex): Boolean; virtual;
    procedure InvalidateSlot(SlotIndex: TLSOMultiWaitSlotIndex); virtual;
    Function CheckIndex(SlotIndex: TLSOMultiWaitSlotIndex): Boolean; virtual;
    property Count: Integer read fSlotCount;
    property SlotPtrs[SlotIndex: TLSOMultiWaitSlotIndex]: PFutex read GetSlot; default;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                 TAdvancedEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TAdvancedEvent - class declaration
===============================================================================}
type
  TAdvancedEvent = class(TEvent)
  protected
    fMultiWaitSlots:  TLSOMultiWaitSlots;
    class Function GetLockType: TLSOLockType; override;
    procedure Initialize(const Name: String; InitializingData: PtrUInt); override;
    procedure Initialize(const Name: String); override;
    procedure Finalize; override;
    // multi-wait methods
    procedure AddWaiter(SlotIndex: TLSOMultiWaitSlotIndex; WaitAll: Boolean); virtual;
    procedure RemoveWaiter(SlotIndex: TLSOMultiWaitSlotIndex); virtual;
    procedure WasLocked; override;
    procedure WasUnlocked; override;
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
                                    TBarrier
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TBarrier - class declaration
===============================================================================}
type
  TBarrier = class(TWrapperLinSyncObject)
  protected
    class Function GetLockType: TLSOLockType; override;
    procedure ResolveLockPtr; override;
    procedure InitializeLock(InitializingData: PtrUInt); override;
    procedure FinalizeLock; override;
  public
    constructor Create(const Name: String; Count: cUnsigned); overload; virtual;
    constructor Create(Count: cUnsigned); overload; virtual;
    constructor Create(const Name: String); override;
    constructor Create; override;
    procedure WaitStrict; virtual;
    Function Wait: Boolean; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                 Wait functions
--------------------------------------------------------------------------------
===============================================================================}
{
  Value of output variable Index is undefined in most cases. Only when WaitAll
  is set to false and the function returns with result being wrSignaled the
  index will contain zero-based index of object that caused the function to
  return.
}

Function WaitForMultipleEvents(Objects: array of TAdvancedEvent; WaitAll: Boolean; Timeout: DWORD; out Index: Integer): TLSOWaitResult;
Function WaitForMultipleEvents(Objects: array of TAdvancedEvent; WaitAll: Boolean; Timeout: DWORD): TLSOWaitResult;
Function WaitForMultipleEvents(Objects: array of TAdvancedEvent; WaitAll: Boolean): TLSOWaitResult;

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
  InterlockedOps, BitOps;

{$IFDEF FPC_DisableWarns}
  {$DEFINE FPCDWM}
  {$DEFINE W5024:={$WARN 5024 OFF}} // Parameter "$1" not used
{$ENDIF}

{===============================================================================
    Error checking and management
===============================================================================}

threadvar
  ThrErrorCode: cInt;

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

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
{===============================================================================
    TLinSyncObject - internals
===============================================================================}
const
  LSO_SHARED_NAMESPACE = 'lso_shared';

type
  TLSOSimpleEvent = record
    Event:  TFutex;
  end;

type
  TLSOWaiterItem = packed record
    SlotIndex:  TLSOMultiWaitSlotIndex;
    WaitAll:    Boolean;
  end;

  TLSOEvent = record
    DataLock:     TFutex;
    WaitFutex:    TFutex;
    Signaled:     Boolean;
    ManualReset:  Boolean;
    WaiterCount:  Integer;
    WaiterArray:  packed array[0..15] of TLSOWaiterItem;
  end;
  PLSOEvent = ^TLSOEvent;

type
  TLSOConditionVariable = record
    DataLock: pthread_mutex_t;
    CondVar:  pthread_cond_t;
  end;

type
  TLSOSharedData = record
    SharedUserData: TLSOSharedUserData;
    RefCount:       Int32;
    case LockType: TLSOLockType of
      ltSpinLock:         (SpinLock:    pthread_spinlock_t);
      ltSimpleManualEvent,
      ltSimpleAutoEvent:  (SimpleEvent: TLSOSimpleEvent);
      ltEvent,
      ltAdvancedEvent:    (Event:       TLSOEvent);
      ltMutex:            (Mutex:       pthread_mutex_t);
      ltSemaphore:        (Semaphore:   sem_t);
      ltRWLock:           (RWLock:      pthread_rwlock_t);
      ltCondVar,
      ltCondVarEx:        (CondVar:     TLSOConditionVariable);
      ltBarrier:          (Barrier:     pthread_barrier_t);
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
If TimeoutSpec.tv_nsec >= 1000000000 then
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

{-------------------------------------------------------------------------------
    TLinSyncObject - public methods
-------------------------------------------------------------------------------}

constructor TLinSyncObject.ProtectedCreate(const Name: String; InitializingData: PtrUInt);
begin
inherited Create;
Initialize(Name,InitializingData);
end;

//------------------------------------------------------------------------------

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
                                TSimpleEventBase
--------------------------------------------------------------------------------
===============================================================================}
const
  LSO_SIMPLEEVENT_LOCKED   = TFutex(0);
  LSO_SIMPLEEVENT_SIGNALED = TFutex(1);

{===============================================================================
    TSimpleEventBase - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TSimpleEventBase - protected methods
-------------------------------------------------------------------------------}

procedure TSimpleEventBase.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.SimpleEvent.Event);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
procedure TSimpleEventBase.InitializeLock(InitializingData: PtrUInt);
begin
InterlockedStore(PLSOSharedData(fSharedData)^.SimpleEvent.Event,LSO_SIMPLEEVENT_LOCKED);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TSimpleEventBase.FinalizeLock;
begin
// no need to do anything
end;

{-------------------------------------------------------------------------------
    TSimpleEventBase - public methods
-------------------------------------------------------------------------------}

procedure TSimpleEventBase.LockStrict;
begin
InterlockedStore32(fLockPtr,LSO_SIMPLEEVENT_LOCKED);
// do not wake any thread
end;

//------------------------------------------------------------------------------

Function TSimpleEventBase.Lock: Boolean;
begin
InterlockedStore32(fLockPtr,LSO_SIMPLEEVENT_LOCKED);
Result := True;
end;

//------------------------------------------------------------------------------

procedure TSimpleEventBase.UnlockStrict;
begin
InterlockedStore32(fLockPtr,LSO_SIMPLEEVENT_SIGNALED);
// wake everyone
FutexWake(PFutex(fLockPtr)^,-1);
end;

//------------------------------------------------------------------------------

Function TSimpleEventBase.Unlock: Boolean;
begin
fLastError := -1;
try
  InterlockedStore32(fLockPtr,LSO_SIMPLEEVENT_SIGNALED);
  FutexWake(PFutex(fLockPtr)^,-1);
  Result := True;
except
  Result := False;
end;
end;


{===============================================================================
--------------------------------------------------------------------------------
                               TSimpleManualEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSimpleManualEvent - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TSimpleManualEvent - protected methods
-------------------------------------------------------------------------------}

class Function TSimpleManualEvent.GetLockType: TLSOLockType;
begin
Result := ltSimpleManualEvent;
end;

{-------------------------------------------------------------------------------
    TSimpleManualEvent - public methods
-------------------------------------------------------------------------------}

procedure TSimpleManualEvent.WaitStrict;
var
  WaitResult: TFutexWaitResult;
begin
repeat
{
  If the event is unlocked, then the following wait will immeditely return with
  result set to fwrValue.
}
  WaitResult := FutexWait(PFutex(fLockPtr)^,LSO_SIMPLEEVENT_LOCKED);
  If not(WaitResult in [fwrWoken,fwrValue]) then
    raise ELSOFutexOpError.CreateFmt('TSimpleManualEvent.WaitStrict: ' +
      'Invalid futex wait result (%d)',[Ord(WaitResult)]);
until InterlockedLoad32(fLockPtr) = LSO_SIMPLEEVENT_SIGNALED;
end;

//------------------------------------------------------------------------------

Function TSimpleManualEvent.Wait: Boolean;
begin
fLastError := -1;
try
  repeat
    Result := FutexWait(PFutex(fLockPtr)^,LSO_SIMPLEEVENT_LOCKED) in [fwrWoken,fwrValue];
    If not Result then
      Break{repeat};
  until InterlockedLoad32(fLockPtr) = LSO_SIMPLEEVENT_SIGNALED;
except
  Result := False;
end;
end;

//------------------------------------------------------------------------------

Function TSimpleManualEvent.TryWaitStrict: Boolean;
begin
Result := InterlockedLoad32(fLockPtr) = LSO_SIMPLEEVENT_SIGNALED;
end;

//------------------------------------------------------------------------------

Function TSimpleManualEvent.TryWait: Boolean;
begin
Result := InterlockedLoad32(fLockPtr) = LSO_SIMPLEEVENT_SIGNALED;
end;

//------------------------------------------------------------------------------

Function TSimpleManualEvent.TimedWait(Timeout: UInt32): TLSOWaitResult;
var
  ExitWait: Boolean;
begin
try
  repeat
    ExitWait := True;
    case FutexWait(PFutex(fLockPtr)^,LSO_SIMPLEEVENT_LOCKED,Timeout) of
    {
      Futex was woken, but that does not necessarily mean it was signaled, so
      check the state.
      Note that it is possible that the futex was woken with unlocked state, but
      before it got here, the state changed back to locked.
    }
      fwrWoken:   If InterlockedLoad32(fLockPtr) = LSO_SIMPLEEVENT_SIGNALED then
                    Result := wrSignaled
                  else
                    ExitWait := False;
    {
      When fwrValue is returned, it means the futex contained value other than
      LSO_EVENT_LOCKED, which means it is not locked, and therefore is considered
      signaled.
    }
      fwrValue:   Result := wrSignaled;
      fwrTimeout: Result := wrTimeout;
    else
      Result := wrError;
    end;
  until ExitWait;
except
  Result := wrError;
end;
end;


{===============================================================================
--------------------------------------------------------------------------------
                                TSimpleAutoEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TSimpleAutoEvent - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TSimpleAutoEvent - protected methods
-------------------------------------------------------------------------------}

class Function TSimpleAutoEvent.GetLockType: TLSOLockType;
begin
Result := ltSimpleAutoEvent;
end;

{-------------------------------------------------------------------------------
    TSimpleAutoEvent - public methods
-------------------------------------------------------------------------------}

procedure TSimpleAutoEvent.WaitStrict;
var
  ExitWait:   Boolean;
  WaitResult: TFutexWaitResult;
begin
repeat
  // lock the event and check what was its original state
  If InterlockedExchange32(fLockPtr,LSO_SIMPLEEVENT_LOCKED) = LSO_SIMPLEEVENT_LOCKED then
    begin
      // event was already locked, enter waiting
      ExitWait := False;
      WaitResult := FutexWait(PFutex(fLockPtr)^,LSO_SIMPLEEVENT_LOCKED);
      If not(WaitResult in [fwrWoken,fwrValue]) then
        raise ELSOFutexOpError.CreateFmt('TSimpleManualEvent.WaitStrict: ' +
          'Invalid futex wait result (%d)',[Ord(WaitResult)]);
      // reapeat the lock-or-wait cycle
    end
  // event was unlocked (and is now locked), exit
  else ExitWait := True;
until ExitWait;
end;

//------------------------------------------------------------------------------

Function TSimpleAutoEvent.Wait: Boolean;
var
  ExitWait: Boolean;
begin
fLastError := -1;
try
  Result := False;
  repeat
    If InterlockedExchange32(fLockPtr,LSO_SIMPLEEVENT_LOCKED) = LSO_SIMPLEEVENT_LOCKED then
      begin
        ExitWait := False;
        If not(FutexWait(PFutex(fLockPtr)^,LSO_SIMPLEEVENT_LOCKED) in [fwrWoken,fwrValue]) then
          Break{repeat};
      end
    else
      begin
        ExitWait := True;
        Result := True;
      end;
  until ExitWait;
except
  Result := False;
end;
end;

//------------------------------------------------------------------------------

Function TSimpleAutoEvent.TryWaitStrict: Boolean;
begin
Result := InterlockedExchange32(fLockPtr,LSO_SIMPLEEVENT_LOCKED) = LSO_SIMPLEEVENT_SIGNALED;
end;

//------------------------------------------------------------------------------

Function TSimpleAutoEvent.TryWait: Boolean;
begin
Result := InterlockedExchange32(fLockPtr,LSO_SIMPLEEVENT_LOCKED) = LSO_SIMPLEEVENT_SIGNALED;
end;

//------------------------------------------------------------------------------

Function TSimpleAutoEvent.TimedWait(Timeout: UInt32): TLSOWaitResult;
var
  ExitWait: Boolean;
begin
try
  repeat
    ExitWait := True;
    // lock the event and check what was its original state
    If InterlockedExchange32(fLockPtr,LSO_SIMPLEEVENT_LOCKED) = LSO_SIMPLEEVENT_LOCKED then
      begin
        // event was already locked, enter waiting
        case FutexWait(PFutex(fLockPtr)^,LSO_SIMPLEEVENT_LOCKED,Timeout) of
          fwrWoken,
          fwrValue:   ExitWait := False;  // event seems to be unlocked, repeat lock cycle
          fwrTimeout: begin
                        // retry locking the event
                        If InterlockedExchange32(fLockPtr,LSO_SIMPLEEVENT_LOCKED) = LSO_SIMPLEEVENT_SIGNALED then
                          Result := wrSignaled
                        else
                          Result := wrTimeout;
                      end;
        else
          Result := wrError;
        end;
      end
    // event was unlocked (and is now locked)
    else Result := wrSignaled;
  until ExitWait;
except
  Result := wrError;
end;
end;


{===============================================================================
--------------------------------------------------------------------------------
                                     TEvent
--------------------------------------------------------------------------------
===============================================================================}
const
  LSO_EVENT_INITDATABIT_STATE    = 0;
  LSO_EVENT_INITDATABIT_MANRESET = 1;

{===============================================================================
    TEvent - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TEvent - protected methods
-------------------------------------------------------------------------------}

class Function TEvent.GetLockType: TLSOLockType;
begin
Result := ltEvent;
end;

//------------------------------------------------------------------------------

procedure TEvent.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.Event);
end;

//------------------------------------------------------------------------------

procedure TEvent.InitializeLock(InitializingData: PtrUInt);
begin
SimpleFutexInit(PLSOSharedData(fSharedData)^.Event.DataLock);
PLSOSharedData(fSharedData)^.Event.WaitFutex := 0;
LockData;
try
  PLSOSharedData(fSharedData)^.Event.Signaled := BT(InitializingData,LSO_EVENT_INITDATABIT_STATE);
  PLSOSharedData(fSharedData)^.Event.ManualReset := BT(InitializingData,LSO_EVENT_INITDATABIT_MANRESET);
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

procedure TEvent.FinalizeLock;
begin
// nothing to do
end;

//------------------------------------------------------------------------------

procedure TEvent.LockData;
begin
SimpleFutexLock(PLSOSharedData(fSharedData)^.Event.DataLock);
end;

//------------------------------------------------------------------------------

procedure TEvent.UnlockData;
begin
SimpleFutexUnlock(PLSOSharedData(fSharedData)^.Event.DataLock);
end;

//------------------------------------------------------------------------------

procedure TEvent.WasLocked;
begin
// do nothing
end;

//------------------------------------------------------------------------------

procedure TEvent.WasUnlocked;
begin
// do nothing
end;

{-------------------------------------------------------------------------------
    TEvent - public methods
-------------------------------------------------------------------------------}

constructor TEvent.Create(const Name: String; ManualReset,InitialState: Boolean);
var
  InitData: PtrUInt;
begin
InitData := 0;
BitSetTo(InitData,LSO_EVENT_INITDATABIT_STATE,InitialState);
BitSetTo(InitData,LSO_EVENT_INITDATABIT_MANRESET,ManualReset);
ProtectedCreate(Name,InitData);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TEvent.Create(ManualReset,InitialState: Boolean);
var
  InitData: PtrUInt;
begin
InitData := 0;
BitSetTo(InitData,LSO_EVENT_INITDATABIT_STATE,InitialState);
BitSetTo(InitData,LSO_EVENT_INITDATABIT_MANRESET,ManualReset);
ProtectedCreate('',InitData);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TEvent.Create(const Name: String);
var
  InitData: PtrUInt;
begin
InitData := 0;
BTS(InitData,LSO_EVENT_INITDATABIT_MANRESET);
ProtectedCreate(Name,InitData);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TEvent.Create;
var
  InitData: PtrUInt;
begin
InitData := 0;
BTS(InitData,LSO_EVENT_INITDATABIT_MANRESET);
ProtectedCreate('',InitData);
end;

//------------------------------------------------------------------------------

procedure TEvent.LockStrict;
var
  OrigState:  Boolean;
begin
LockData;
try
  OrigState := PLSOEvent(fLockPtr)^.Signaled;
  PLSOEvent(fLockPtr)^.Signaled := False;
  If OrigState then
    WasLocked;
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

Function TEvent.Lock: Boolean;
var
  OrigState:  Boolean;
begin
fLastError := -1;
LockData;
try
  try
    OrigState := PLSOEvent(fLockPtr)^.Signaled;
    PLSOEvent(fLockPtr)^.Signaled := False;
    If OrigState then
      WasLocked;
    Result := True;
  except
    Result := False;
  end;
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

procedure TEvent.UnlockStrict;
var
  OrigState:  Boolean;
begin
LockData;
try
  OrigState := PLSOEvent(fLockPtr)^.Signaled;
  PLSOEvent(fLockPtr)^.Signaled := True;
  If not OrigState then
    WasUnlocked;
{
  All waitings (FutexWait) are immediately followed by data lock. So if we wake
  any thread, it will just run into locked data lock.
  To prevent this, we requeue all threads waiting on this event to wait on the
  data lock. Internal workings of the data lock then takes care of them.

  No waiting thread is explicitly woken.
}
  If FutexCmpRequeue(PLSOEvent(fLockPtr)^.WaitFutex,0,PLSOEvent(fLockPtr)^.DataLock,0,MAXINT) < 0 then
    raise ELSOFutexOpError.Create('TEvent.UnlockStrict: Failed to requeue waiters.');
  SimpleFutexQueue(PLSOEvent(fLockPtr)^.DataLock);
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

Function TEvent.Unlock: Boolean;
var
  OrigState:  Boolean;
begin
fLastError := -1;
LockData;
try
  try
    OrigState := PLSOEvent(fLockPtr)^.Signaled;
    PLSOEvent(fLockPtr)^.Signaled := True;
    If not OrigState then
      WasUnlocked;
    Result := FutexCmpRequeue(PLSOEvent(fLockPtr)^.WaitFutex,0,PLSOEvent(fLockPtr)^.DataLock,0,MAXINT) >= 0;
    SimpleFutexQueue(PLSOEvent(fLockPtr)^.DataLock);
  except
    Result := False;
  end;
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

procedure TEvent.WaitStrict;
var
  ExitWait:   Boolean;
  WaitResult: TFutexWaitResult;
begin
LockData;
try
  repeat
    ExitWait := True;
    If not PLSOEvent(fLockPtr)^.Signaled then
      begin
        UnlockData;
        try
          WaitResult := FutexWait(PLSOEvent(fLockPtr)^.WaitFutex,0);
        finally
          LockData;
        end;
        If WaitResult <> fwrWoken then
          raise ELSOFutexOpError.CreateFmt('TEvent.WaitStrict: ' +
            'Invalid futex wait result (%d)',[Ord(WaitResult)]);
      end;
    If PLSOEvent(fLockPtr)^.Signaled then
      begin
        If not PLSOEvent(fLockPtr)^.ManualReset then
          begin
            PLSOEvent(fLockPtr)^.Signaled := False;
            WasLocked;
          end;
      end
    else ExitWait := False;
  until ExitWait
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

Function TEvent.Wait: Boolean;
var
  ExitWait:   Boolean;
  WaitResult: TFutexWaitResult;
begin
fLastError := -1;
Result := False;
LockData;
try
  try
    repeat
      ExitWait := True;
      If not PLSOEvent(fLockPtr)^.Signaled then
        begin
          UnlockData;
          try
            WaitResult := FutexWait(PLSOEvent(fLockPtr)^.WaitFutex,0);
          finally
            LockData;
          end;
          If WaitResult <> fwrWoken then
            Break{repeat};
        end;
      If PLSOEvent(fLockPtr)^.Signaled then
        begin
          If not PLSOEvent(fLockPtr)^.ManualReset then
            begin
              PLSOEvent(fLockPtr)^.Signaled := False;
              WasLocked;
            end;
          Result := True;
        end
      else ExitWait := False;
    until ExitWait
  except
    Result := False;
  end;
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

Function TEvent.TryWaitStrict: Boolean;
begin
LockData;
try
  Result := PLSOEvent(fLockPtr)^.Signaled;
  If not PLSOEvent(fLockPtr)^.ManualReset then
    begin
      PLSOEvent(fLockPtr)^.Signaled := False;
      If Result then
        WasLocked;
    end;
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

Function TEvent.TryWait: Boolean;
begin
fLastError := -1;
LockData;
try
  try
    Result := PLSOEvent(fLockPtr)^.Signaled;
    If not PLSOEvent(fLockPtr)^.ManualReset then
      begin
        PLSOEvent(fLockPtr)^.Signaled := False;
        If Result then
          WasLocked;
      end;
  except
    Result := False;
  end;
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

Function TEvent.TimedWait(Timeout: UInt32): TLSOWaitResult;
var
  ExitWait:   Boolean;
  WaitResult: TFutexWaitResult;
begin
// note that time spent in data locking is ignored and is not projected to timeout
LockData;
try
  try
    repeat
      ExitWait := True;
      If not PLSOEvent(fLockPtr)^.Signaled then
        begin
          UnlockData;
          try
            WaitResult := FutexWait(PLSOEvent(fLockPtr)^.WaitFutex,0,Timeout);
          finally
            LockData;
          end;
          case WaitResult of
            fwrWoken:   Result := wrSignaled;
            fwrTimeout: Result := wrTimeout;
          else
            Result := wrError;
          end;
        end;
      If PLSOEvent(fLockPtr)^.Signaled then
        begin
          If not PLSOEvent(fLockPtr)^.ManualReset then
            begin
              PLSOEvent(fLockPtr)^.Signaled := False;
              WasLocked;
            end;
          Result := wrSignaled;
        end
      else If Result <> wrTimeout then
        ExitWait := False;
    until ExitWait
  except
    Result := wrError;
  end;
finally
  UnlockData;
end;
end;


{===============================================================================
--------------------------------------------------------------------------------
                               TLSOMultiWaitSlots
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TLSOMultiWaitSlots - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TLSOMultiWaitSlots - protected methods
-------------------------------------------------------------------------------}

Function TLSOMultiWaitSlots.GetSlot(SlotIndex: TLSOMultiWaitSlotIndex): PFutex;
begin
If CheckIndex(SlotIndex) then
  Result := PFutex(PtrAdvance(fSlotMemory,SlotIndex,SizeOf(TFutex)))
else
  raise ELSOIndexOutOfBounds.CreateFmt('TLSOMultiWaitSlots.GetSlot: Slot index (%d) out of bounds.',[SlotIndex]);
end;

//------------------------------------------------------------------------------

procedure TLSOMultiWaitSlots.Initialize;
begin
inherited;
fSlotCount := 15360;  // 15 * 1024
fSlotMap := TBitVector.Create(fMemory,fSlotCount);
fSlotMemory := PtrAdvance(fMemory,2048);
end;

//------------------------------------------------------------------------------

procedure TLSOMultiWaitSlots.Finalize;
begin
fSlotMemory := nil;
fSlotMap.Free;
inherited;
end;

{-------------------------------------------------------------------------------
    TLSOMultiWaitSlots - public methods
-------------------------------------------------------------------------------}

constructor TLSOMultiWaitSlots.Create;
begin
inherited Create(65536{64KiB},'lso_multiwaitslots');
end;

//------------------------------------------------------------------------------

Function TLSOMultiWaitSlots.GetFreeSlotIndex(out SlotIndex: TLSOMultiWaitSlotIndex): Boolean;
begin
Lock;
try
  SlotIndex := TLSOMultiWaitSlotIndex(fSlotMap.FirstClean);
  Result := CheckIndex(SlotIndex);
finally
  Unlock;
end;
end;

//------------------------------------------------------------------------------

procedure TLSOMultiWaitSlots.InvalidateSlot(SlotIndex: TLSOMultiWaitSlotIndex);
begin
Lock;
try
  If CheckIndex(SlotIndex) then
    begin
      fSlotMap[SlotIndex] := False;
      PFutex(PtrAdvance(fSlotMemory,SlotIndex,SizeOf(TFutex)))^ := 0;
    end
  else ELSOIndexOutOfBounds.CreateFmt('TLSOMultiWaitSlots.InvalidateSlot: Slot index (%d) out of bounds.',[SlotIndex]);
finally
  Unlock;
end;
end;

//------------------------------------------------------------------------------

Function TLSOMultiWaitSlots.CheckIndex(SlotIndex: TLSOMultiWaitSlotIndex): Boolean;
begin
Result := (SlotIndex >= 0) and (SlotIndex < fSlotCount);
end;


{===============================================================================
--------------------------------------------------------------------------------
                                 TAdvancedEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TAdvancedEvent - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TAdvancedEvent - protected methods
-------------------------------------------------------------------------------}

class Function TAdvancedEvent.GetLockType: TLSOLockType;
begin
Result := ltAdvancedEvent;
end;

//------------------------------------------------------------------------------

procedure TAdvancedEvent.Initialize(const Name: String; InitializingData: PtrUInt);
begin
inherited Initialize(Name,InitializingData);
fMultiWaitSlots := TLSOMultiWaitSlots.Create;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

procedure TAdvancedEvent.Initialize(const Name: String);
begin
inherited Initialize(Name);
fMultiWaitSlots := TLSOMultiWaitSlots.Create;
end;

//------------------------------------------------------------------------------

procedure TAdvancedEvent.Finalize;
begin
fMultiWaitSlots.Free;
inherited;
end;

//------------------------------------------------------------------------------

procedure TAdvancedEvent.AddWaiter(SlotIndex: TLSOMultiWaitSlotIndex; WaitAll: Boolean);
begin
LockData;
try
  with PLSOEvent(fLockPtr)^ do
    begin
      If WaiterCount < Length(WaiterArray) then
        begin
          WaiterArray[WaiterCount].SlotIndex := SlotIndex;
          WaiterArray[WaiterCount].WaitAll := WaitAll;
          If Signaled then
            InterlockedDecrement(fMultiWaitSlots[WaiterArray[WaiterCount].SlotIndex]^);
          Inc(WaiterCount);
        end
      else raise ELSOMultiWaitError.Create('TAdvancedEvent.AddWaiter: Waiter list full.');
    end;
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

procedure TAdvancedEvent.RemoveWaiter(SlotIndex: TLSOMultiWaitSlotIndex);
var
  i:      Integer;
  Index:  Integer;
begin
LockData;
try
  with PLSOEvent(fLockPtr)^ do
    begin
      // find the futex
      Index := -1;
      For i := Low(WaiterArray) to Pred(WaiterCount) do
        If WaiterArray[i].SlotIndex = SlotIndex then
          begin
            Index := i;
            Break{For i};
          end;
      // now remove it
      If Index >= 0 then
        begin
          For i := Index to (WaiterCount - 2) do
            WaiterArray[i] := WaiterArray[i + 1];
          Dec(WaiterCount);
        end
      else raise ELSOMultiWaitError.Create('TAdvancedEvent.RemoveWaiter: Waiter not found.');
    end;
finally
  UnlockData;
end;
end;

//------------------------------------------------------------------------------

procedure TAdvancedEvent.WasLocked;
var
  i:  Integer;
begin
// data are expected to be locked by now
with PLSOEvent(fLockPtr)^ do
  For i := Low(WaiterArray) to Pred(WaiterCount) do
    InterlockedIncrement(fMultiWaitSlots[WaiterArray[WaiterCount].SlotIndex]^);
// do not wake the waiter
end;

//------------------------------------------------------------------------------

procedure TAdvancedEvent.WasUnlocked;
var
  i:  Integer;
begin
// data are expected to be locked by now
with PLSOEvent(fLockPtr)^ do
  For i := Low(WaiterArray) to Pred(WaiterCount) do
    begin
      If WaiterArray[i].WaitAll then
        begin
          If InterlockedDecrement(fMultiWaitSlots[WaiterArray[WaiterCount].SlotIndex]^) <= 0 then
            FutexWake(fMultiWaitSlots[WaiterArray[WaiterCount].SlotIndex]^,1);
        end
      else
        begin
          InterlockedDecrement(fMultiWaitSlots[WaiterArray[WaiterCount].SlotIndex]^);
          FutexWake(fMultiWaitSlots[WaiterArray[WaiterCount].SlotIndex]^,1);
        end;
    end;
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
try
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
except
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
try
  Result := wrError;
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
except
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
try
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
except
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
try
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
except
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
fLockPtr := Addr(PLSOSharedData(fSharedData)^.CondVar.CondVar);
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
    If not CheckResErr(pthread_cond_init(Addr(PLSOSharedData(fSharedData)^.CondVar.CondVar),@CondVarAttr)) then
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
If not CheckResErr(pthread_cond_destroy(Addr(PLSOSharedData(fSharedData)^.CondVar.CondVar))) then
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
try
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
except
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
inherited;
fDataLockPtr := Addr(PLSOSharedData(fSharedData)^.CondVar.DataLock);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
procedure TConditionVariableEx.InitializeLock(InitializingData: PtrUInt);
var
  MutexAttr:  pthread_mutexattr_t;
begin
inherited InitializeLock(InitializingData);
// data-lock mutex
If CheckResErr(pthread_mutexattr_init(@MutexAttr)) then
  try
    If fProcessShared then
      If not CheckResErr(pthread_mutexattr_setpshared(@MutexAttr,PTHREAD_PROCESS_SHARED)) then
        raise ELSOSysOpError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
          'Failed to set data-lock mutex attribute PSHARED (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckResErr(pthread_mutex_init(Addr(PLSOSharedData(fSharedData)^.CondVar.DataLock),@MutexAttr)) then
      raise ELSOSysInitError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
        'Failed to initialize data-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckResErr(pthread_mutexattr_destroy(@MutexAttr)) then
      raise ELSOSysFinalError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
        'Failed to destroy data-lock mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TConditionVariableEx.InitializeLock: ' +
       'Failed to initialize data-lock mutex attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TConditionVariableEx.FinalizeLock;
begin
If not CheckResErr(pthread_mutex_destroy(Addr(PLSOSharedData(fSharedData)^.CondVar.DataLock))) then
  raise ELSOSysFinalError.CreateFmt('TConditionVariableEx.FinalizeLock: ' +
    'Failed to destroy data-lock mutex (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
inherited;
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
                                    TBarrier
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TBarrier - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TBarrier - protected methods
-------------------------------------------------------------------------------}

class Function TBarrier.GetLockType: TLSOLockType;
begin
Result := ltBarrier;
end;

//------------------------------------------------------------------------------

procedure TBarrier.ResolveLockPtr;
begin
fLockPtr := Addr(PLSOSharedData(fSharedData)^.Barrier);
end;

//------------------------------------------------------------------------------

procedure TBarrier.InitializeLock(InitializingData: PtrUInt);
var
  BarrierAttr:  pthread_barrierattr_t;
begin
If CheckResErr(pthread_barrierattr_init(@BarrierAttr)) then
  try
    If fProcessShared then
      If not CheckResErr(pthread_barrierattr_setpshared(@BarrierAttr,PTHREAD_PROCESS_SHARED)) then
        raise ELSOSysOpError.CreateFmt('TBarrier.InitializeLock: ' +
          'Failed to set barrier attribute PSHARED (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
    If not CheckResErr(pthread_barrier_init(Addr(PLSOSharedData(fSharedData)^.Barrier),@BarrierAttr,cUnsigned(InitializingData))) then
      raise ELSOSysInitError.CreateFmt('TBarrier.InitializeLock: ' +
        'Failed to initialize barrier (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  finally
    If not CheckResErr(pthread_barrierattr_destroy(@BarrierAttr)) then
      raise ELSOSysFinalError.CreateFmt('TBarrier.InitializeLock: ' +
        'Failed to destroy barrier attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
  end
else raise ELSOSysInitError.CreateFmt('TBarrier.InitializeLock: ' +
       'Failed to initialize barrier attributes (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

procedure TBarrier.FinalizeLock;
begin
If not CheckResErr(pthread_barrier_destroy(Addr(PLSOSharedData(fSharedData)^.Barrier))) then
  raise ELSOSysFinalError.CreateFmt('TBarrier.FinalizeLock: ' +
    'Failed to destroy barrier (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

{-------------------------------------------------------------------------------
    TBarrier - public methods
-------------------------------------------------------------------------------}

constructor TBarrier.Create(const Name: String; Count: cUnsigned);
begin
ProtectedCreate(Name,PtrUInt(Count));
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TBarrier.Create(Count: cUnsigned);
begin
ProtectedCreate('',PtrUInt(Count));
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TBarrier.Create(const Name: String);
begin
ProtectedCreate(Name,1);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TBarrier.Create;
begin
ProtectedCreate('',1);
end;

//------------------------------------------------------------------------------

procedure TBarrier.WaitStrict;
begin
If not CheckResErr(pthread_barrier_wait(fLockPtr)) then
  If ThrErrorCode <> PTHREAD_BARRIER_SERIAL_THREAD then
    raise ELSOSysOpError.CreateFmt('TBarrier.WaitStrict: ' +
      'Failed to wait on barrier (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function TBarrier.Wait: Boolean;
begin
Result := CheckResErr(pthread_barrier_wait(fLockPtr));
If not Result and (ThrErrorCode = PTHREAD_BARRIER_SERIAL_THREAD) then
  begin
    Result := True;
    fLastError := 0;
  end
else fLastError := Integer(ThrErrorCode);
end;


{===============================================================================
--------------------------------------------------------------------------------
                                 Wait functions
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    Wait functions - internal functions
===============================================================================}

Function GetTimeAsMilliseconds: Int64;
var
  TimeSpec: TTimeSpec;
begin
If CheckErr(clock_gettime(CLOCK_MONOTONIC_RAW,@TimeSpec)) then
  Result := (((Int64(TimeSpec.tv_sec) * 1000) + (Int64(TimeSpec.tv_nsec) div 1000000))) and (Int64(-1) shr 1)
else
  raise ELSOSysOpError.CreateFmt('GetTimeAsMilliseconds: Unable to obtain time (%d - %s).',[ThrErrorCode,StrError(ThrErrorCode)]);
end;

//------------------------------------------------------------------------------

Function WaitForMultipleEvents_Internal(Objects: array of TAdvancedEvent; Timeout: DWORD; WaitAll: Boolean; out Index: Integer): TLSOWaitResult;
var
  MultiWaitSlots: TLSOMultiWaitSlots;
  WaiterFutexIdx: TLSOMultiWaitSlotIndex;
  WaiterFutexPtr: PFutex;
  i:              Integer;
  StartTime:      Int64;
  CurrTime:       Int64;
  ExitWait:       Boolean;
  Counter:        Integer;
  SigIndex:       Integer;
begin
// this function cannot produce usable index
Index := -1;
// init waiter futex
MultiWaitSlots := TLSOMultiWaitSlots.Create;
try
  If MultiWaitSlots.GetFreeSlotIndex(WaiterFutexIdx) then
    try
      WaiterFutexPtr := MultiWaitSlots[WaiterFutexIdx];
      WaiterFutexPtr^ := Length(Objects);
      // add waiter futex to all events
      For i := Low(Objects) to High(Objects) do
        Objects[i].AddWaiter(WaiterFutexIdx,WaitAll);
      try
        // do the waiting
        Counter := Length(Objects);
        repeat
          ExitWait := True;
          StartTime := GetTimeAsMilliseconds;
          If not WaitAll then
            Counter := Length(Objects);
          case FutexWait(WaiterFutexPtr^,TFutex(Counter),Timeout) of
            fwrWoken,
            fwrValue:   begin
                          // lock all objects to prevent change in their state
                          For i := Low(Objects) to High(Objects) do
                            Objects[i].LockData;
                          try
                            If WaitAll then
                              begin
                                // check state of all objects
                                Counter := Length(Objects);
                                For i := Low(Objects) to High(Objects) do
                                  If PLSOEvent(Objects[i].fLockPtr)^.Signaled then
                                    Dec(Counter);
                                // if all are signaled, change state of auto-reset events to locked
                                If Counter <= 0 then
                                  begin
                                    For i := Low(Objects) to High(Objects) do
                                      If not PLSOEvent(Objects[i].fLockPtr)^.ManualReset then
                                        PLSOEvent(Objects[i].fLockPtr)^.Signaled := False;
                                    Result := wrSignaled;
                                  end
                                else ExitWait := False; // spurious wakeup
                              end
                            else
                              begin
                                // find first signaled event
                                SigIndex := -1;
                                For i := Low(Objects) to High(Objects) do
                                  If PLSOEvent(Objects[i].fLockPtr)^.Signaled then
                                    begin
                                      SigIndex := i;
                                      Break{For i};
                                    end;
                                If SigIndex >= 0 then
                                  begin
                                    If not PLSOEvent(Objects[SigIndex].fLockPtr)^.ManualReset then
                                      PLSOEvent(Objects[SigIndex].fLockPtr)^.Signaled := False;
                                    Index := SigIndex;
                                    Result := wrSignaled;
                                  end
                                else ExitWait := False; // spurious wakeup
                              end;
                          finally
                            // unlock all objects
                            For i := Low(Objects) to High(Objects) do
                              Objects[i].UnlockData;
                          end;
                        end;
            fwrTimeout: Result := wrTimeout;
          else
            Result := wrError;
          end;
          // recalculate timeout
          If not ExitWait then
            begin
              CurrTime := GetTimeAsMilliseconds;
              If CurrTime > StartTime then
                begin
                  If Timeout <= (CurrTime - StartTime) then
                    begin
                      Result := wrTimeout;
                      Break{repeat};
                    end
                  else Timeout := Timeout - (CurrTime - StartTime);
                end;
            end;
        until ExitWait;
      finally
        // remove waiter futex from all events
        For i := Low(Objects) to High(Objects) do
          Objects[i].RemoveWaiter(WaiterFutexIdx);
      end;
    finally
      MultiWaitSlots.InvalidateSlot(WaiterFutexIdx);
    end
  else raise ELSOMultiWaitError.Create('WaitForMultipleEvents_Internal: No wait slot available.');
finally
  MultiWaitSlots.Free;
end;
end;

{===============================================================================
    Wait functions - public functions
===============================================================================}

Function WaitForMultipleEvents(Objects: array of TAdvancedEvent; WaitAll: Boolean; Timeout: DWORD; out Index: Integer): TLSOWaitResult;
begin
Index := -1;
If Length(Objects) > 1 then
   Result := WaitForMultipleEvents_Internal(Objects,Timeout,WaitAll,Index)
else If Length(Objects) = 1 then
  begin
    Result := Objects[0].TimedWait(Timeout);
    If Result = wrSignaled then
      Index := 0;
  end
else raise ELSOMultiWaitError.CreateFmt('WaitForMultipleEvents: Invalid object count (%d).',[Length(Objects)]);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function WaitForMultipleEvents(Objects: array of TAdvancedEvent; WaitAll: Boolean; Timeout: DWORD): TLSOWaitResult;
var
  Index:  Integer;
begin
Result := WaitForMultipleEvents(Objects,WaitAll,Timeout,Index);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function WaitForMultipleEvents(Objects: array of TAdvancedEvent; WaitAll: Boolean): TLSOWaitResult;
var
  Index:  Integer;
begin
Result := WaitForMultipleEvents(Objects,WaitAll,INFINITE,Index);
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

