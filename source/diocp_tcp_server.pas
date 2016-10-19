(*
 *	 Unit owner: D10.Mofen
 *         homePage: http://www.diocp.org
 *	       blog: http://www.cnblogs.com/dksoft

 *   2015-02-22 08:29:43
 *     DIOCP-V5 发布
 *
 *   2015-04-10 18:00:52
 *     停止时加入等待所有的投递的AcceptEx请求回归回归后再进行关闭IOCP引擎,(会导致投递出去的AcceptEx无法回归(XP下出现泄漏))
 *     感谢 Xjumping  990669769, 反馈bug
 *
 *
 *   thanks qsl's suggestion
 *
 *
 *)
 
unit diocp_tcp_server;

{$I 'diocp.inc'}



{$IFDEF DEBUG}
  {$DEFINE DEBUG_ON}
  //输出日志记录编译开关
  {$DEFINE WRITE_LOG}
{$ENDIF}



// 详细记录接收信息
{.$DEFINE TRACE_IOCP_RECV}

// 详细记录发送信息
{.$DEFINE TRACE_IOCP_SEND}


{$IFDEF DIOCP_HIGH_SPEED}
  {$UNDEF WRITE_LOG}
  {$UNDEF DEBUG_ON}
  {$UNDEF DIOCP_DEBUG}
  {$UNDEF TRACE_IOCP_RECV}
  {$UNDEF TRACE_IOCP_SEND}
{$ENDIF}


interface 

uses
  Classes, diocp_sockets_utils, diocp_core_engine,
  winsock, diocp_winapi_winsock2, diocp_res,

{$if CompilerVersion >= 18}
  types,
{$ifend}

  diocp_core_rawWinSocket, SyncObjs, Windows, SysUtils,
  utils_safeLogger,
  utils_hashs,
  utils_queues, utils_locker, utils_strings, utils_threadinfo
  
  , utils_byteTools
  , utils_BufferPool;

const
  SOCKET_HASH_SIZE = $FFFF;
  FREE_FLAG = $01;

  CORE_LOG_FILE = 'diocp_core_exception';
  CORE_DEBUG_FILE = 'diocp_core_debug';

  ADDRESS_LENGTH_EX = 18;

  IP_V4 = 0;
  IP_V6 = 1;

type
  TDiocpTcpServer = class;
  TIocpAcceptorMgr = class;
  TIocpClientContext = class;
  TIocpRecvRequest = class;
  TIocpSendRequest = class;
  TIocpDisconnectExRequest = class;

  TDataReleaseType = (dtNone, dtFreeMem, dtDispose);

  TIocpClientContextClass = class of TIocpClientContext;

  TOnContextError = procedure(pvClientContext: TIocpClientContext; errCode:
      Integer) of object;

  TOnSendRequestResponse = procedure(pvContext:TIocpClientContext;
      pvRequest:TIocpSendRequest) of object;

  TOnDataReceived = procedure(pvClientContext:TIocpClientContext;
      buf:Pointer; len:cardinal; errCode:Integer) of object;

  TOnBufferEvent = procedure(pvContext: TIocpClientContext; pvBuff: Pointer; len:
      Cardinal; pvBufferTag, pvErrorCode: Integer) of object;

  TOnContextAcceptEvent = procedure(pvSocket: THandle; pvAddr: String; pvPort:
      Integer; var vAllowAccept: Boolean) of object;

  TContextNotifyEvent = procedure(pvClientContext: TIocpClientContext) of object;

  /// <summary>
  ///   on post request is completed
  /// </summary>
  TOnDataRequestCompleted = procedure(pvClientContext:TIocpClientContext;
      pvRequest:TIocpRequest) of object;


  TDiocpListener = class(TObject)
  private
    FAcceptorMgr: TIocpAcceptorMgr;
    FListenAddress:string;
    FListenPort: Word;
    FIPVersion: Integer;
  public
    constructor Create(AOwnerTcpServer: TDiocpTcpServer);
    destructor Destroy; override;
    procedure Start(pvIocpEngine: TIocpEngine);
    procedure PostAcceptExRequest(pvNum: Integer);
    procedure WaitForCancel(pvTimeOut:Integer);
    procedure Close;
  end;

  /// <summary>
  ///   该类非线程安全，请不要多线程操作一个对象
  /// </summary>
  TDiocpListeners = class(TObject)
  private
    FList: TList;
    FOwnerServer:TDiocpTcpServer;
    procedure Clear;
  public
    constructor Create(AOwnerTcpServer: TDiocpTcpServer);
    destructor Destroy; override;


    procedure Bind(const pvBindingAddress: string; const pvPort: Integer;
        pvIPVersion: Integer = IP_V4; pvClientContextClass: TIocpClientContextClass
        = nil);

    procedure Close;

    procedure WaitForCancel(pvTimeOut:Integer);

    procedure ClearObjects;
    procedure PostAcceptExRequest(pvNum: Integer);
    procedure Start(pvIocpEngine: TIocpEngine);

  end;

  /// <summary>
  ///   远程连接类
  ///   对应客户端的一个连接
  /// </summary>
  TIocpClientContext = class(TObject)
  private
    __free_flag:Integer;

    // 大于0时不会被KickOut
    FBusingCounter: Integer; 

    // 当前建立的连接套接字句柄
    FSocketHandle:TSocket;

    FCheckThreadId: THandle;

    // 最后交互数据的时间点
    FLastActivity: Cardinal;

    FDebugStrings:TStrings;

    {$IFDEF SOCKET_REUSE}
    FDisconnectExRequest:TIocpDisconnectExRequest;
    {$ENDIF}

    FSocketState: TSocketState;

    /// <summary>
    ///   被引用的计数器, 当计数器为0时可以进行关闭释放
    /// </summary>
    FReferenceCounter:Integer;

    /// <summary>
    ///   是否被请求关闭的标志，如果为true时 和引用计数器为0 时进行真正的关闭连接
    /// </summary>
    FRequestDisconnect:Boolean;


    FManulPostWSARecvRequest:Boolean;



    FDebugInfo: string;
    procedure SetDebugInfo(const Value: string);



    /// <summary>
    ///   增加引用计数
    /// </summary>
    /// <returns>
    ///   成功返回true,
    ///   失败返回false 当前连接正在请求关闭
    /// </returns>
    /// <param name="pvDebugInfo"> 调试记录信息 </param>
    /// <param name="pvObj"> 调试记录对象 </param>
    function IncReferenceCounter(pvDebugInfo: string; pvObj: TObject): Boolean;

    /// <summary>
    ///  减少引用计数
    ///  当引用计数器 = 0和请求关闭标志为true时，会调用断开函数(InnerCloseContext)
    /// </summary>
    function DecReferenceCounter(pvDebugInfo: string; pvObj: TObject): Integer;

    /// <summary>
    ///   减少引用计数，并请求关闭
    ///   当引用计数器 = 0时，会调用断开函数(InnerCloseContext)
    /// </summary>
    procedure DecReferenceCounterAndRequestDisconnect(pvDebugInfo: string; pvObj:
        TObject);


  {$IFDEF SOCKET_REUSE}
    /// <summary>
    ///   套接字重用时使用，用于响应DisconnectEx请求事件
    /// </summary>
    procedure OnDisconnectExResponse(pvObject:TObject);
  {$ENDIF}
  private
    /// <summary>
    ///   断线原因
    /// </summary>
    FDisconnectedReason:String;

    FAlive:Boolean;

    FInnerLockerFlag: Integer;

    /// 开始工作时间
    FWorkerStartTick:Cardinal;

    /// 结束工作时间
    FWorkerEndTick: Cardinal;

    FContextLocker: TIocpLocker;


    /// <summary>
    ///  正在发送标记
    /// </summary>
    FSending: Boolean;

    FActive: Boolean;


    /// <summary>
    ///   正在请求关闭,不响应任何的接收数据事件
    /// </summary>
    FRequestClose: Byte;


    /// <summary>
    ///  当前正在发送的请求
    /// </summary>
    FCurrSendRequest:TIocpSendRequest;

    FCurrRecvRequest:TIocpRecvRequest;
    
    FData: Pointer;

    /// <summary>
    ///  连接的DNA，每次连接都会进行一次累加
    /// </summary>
    FContextDNA: Integer;

    /// <summary>
    ///   发送请求链表，默认最大列表大小为100,可以在开启服务前进行设置
    /// </summary>
    FSendRequestLink: TIocpRequestSingleLink;

    FRawSocket: TRawSocket;

    FRemoteAddr: String;
    FRemotePort: Integer;
    FTagStr: String;


    /// <summary>
    ///   在投递的接收请求响应中调用，触发接收数据事件
    /// </summary>
    procedure DoReceiveData(pvRecvRequest: TIocpRecvRequest);



    /// <summary>
    ///   post next sendRequest
    ///    must single thread operator
    /// </summary>
    procedure CheckNextSendRequest;

    /// <example>
    ///   释放资源
    ///    1.发送队列中的未发送的请求(TSendRequest), 会调用发送实例的TSendRequest.CancelRequest
    /// </example>
    procedure CheckReleaseRes;


    procedure SetOwner(const Value: TDiocpTcpServer);
    function GetDebugInfo: string;

    /// <summary>
    ///   归还释放
    /// </summary>
    procedure ReleaseBack;

  protected
    FAcceptorMgr:TIocpAcceptorMgr;


    FOwner: TDiocpTcpServer;
    
    /// <summary>
    ///   连接的接收请求实例
    /// </summary>
    /// FRecvRequest:TIocpRecvRequest;

    /// <summary>
    ///   投递接收请求
    /// </summary>
    procedure PostWSARecvRequest();virtual;

    /// <summary>
    ///   called by sendRequest response
    /// </summary>
    procedure DoSendRequestCompleted(pvRequest: TIocpSendRequest); virtual;

    /// <summary>
    ///
    /// </summary>
    function GetSendRequest: TIocpSendRequest;

    /// <summary>
    ///   Give Back
    /// </summary>
    function ReleaseSendRequest(pvObject:TIocpSendRequest): Boolean;

    /// <summary>
    ///  1.post reqeust to sending queue,
    ///    return false if SendQueue Size is greater than maxSize,
    ///
    ///  2.check sending flag, start if sending is false
    /// </summary>
    function InnerPostSendRequestAndCheckStart(pvSendRequest:TIocpSendRequest): Boolean;

    /// <summary>
    ///   执行真正的连接断开清理工作触发事件
    ///   单线程调用
    /// </summary>
    procedure InnerCloseContext;

    /// <summary>
    ///   投递完成后，继续投递下一个请求,
    ///     只在HandleResponse中调用
    /// </summary>
    procedure PostNextSendRequest; virtual;


    /// <summary>
    ///   投递的发送请求响应时执行，一响应，马上执行，Errcode <> 0也会响应
    /// </summary>
    procedure DoSendRequestRespnonse(pvRequest: TIocpSendRequest); virtual;

    procedure InnerLock();{$IFDEF HAVE_INLINE} inline;{$ENDIF}
    procedure InnerUnLock();{$IFDEF HAVE_INLINE} inline;{$ENDIF}
    procedure Lock();{$IFDEF HAVE_INLINE} inline;{$ENDIF}
    procedure UnLock;
  protected
    procedure DoConnected;

    procedure DoDisconnected;

    /// <summary>
    ///   归还到池时进行调用
    /// </summary>
    procedure DoCleanUp;virtual;

    procedure OnRecvBuffer(buf: Pointer; len: Cardinal; ErrCode: WORD); virtual;

    procedure OnDisconnected; virtual;

    procedure OnConnected; virtual;

    procedure SetSocketState(pvState:TSocketState); virtual;

    procedure DoSendBufferCompleted(pvBuffer: Pointer; len: Cardinal; pvBufferTag,
        pvErrorCode: Integer); virtual;

    procedure RecordWorkerStartTick;
    procedure RecordWorkerEndTick;
  public
    
    procedure AddDebugString(pvString:string);

    /// <summary>
    ///   检测当前正在工作耗用时间
    /// </summary>
    /// <returns>
    ///  耗用毫秒数, 如果没有工作（或者已经结束工作)，则返回0
    /// </returns>
    function CheckWorkingTick: Cardinal;

    /// <summary>
    ///   获取当前待发送队列中的请求数量
    /// </summary>
    function GetSendQueueSize: Integer;

    procedure BeginBusy();
    procedure EndBusy;


    constructor Create; virtual;
    destructor Destroy; override;
    procedure CheckThreadIn;
    procedure CheckThreadOut;

    procedure DoDisconnect;

    /// <summary>
    ///   锁定Context连接，避免关闭归还到Context对象池
    ///    锁定成功返回True, 否则返回False(连接已经被断开或者申请断开)
    /// </summary>
    function LockContext(pvDebugInfo: string; pvObj: TObject): Boolean;


    procedure UnLockContext(pvDebugInfo: string; pvObj: TObject);

    /// <summary>
    ///   投递关闭请求
    ///     等待前面的数据发送请求进行关闭后，然后进行断开操作
    /// </summary>
    procedure PostWSACloseRequest();

    procedure RequestDisconnect(pvReason: string = ''; pvObj: TObject = nil);

    /// <summary>
    ///  post send request to iocp queue, if post successful return true.
    ///    if request is completed, will call DoSendRequestCompleted procedure
    /// </summary>
    function PostWSASendRequest(buf: Pointer; len: Cardinal; pvCopyBuf: Boolean =
        true; pvTag: Integer = 0; pvTagData: Pointer = nil): Boolean; overload;

    /// <summary>
    ///    投递发送请求到IOCP队列
    ///    post send request to iocp queue, if post successful return true.
    ///      if request is completed, will call DoSendRequestCompleted procedure
    ///    如果 长度为0, 则在处理请求时进行关闭。
    /// </summary>
    /// <returns>
    ///    如果投递成功返回true。否则返回false(投递队列已满)
    /// </returns>
    /// <param name="buf"> (Pointer) </param>
    /// <param name="len"> (Cardinal) </param>
    /// <param name="pvBufReleaseType"> 释放类型 </param>
    /// <param name="pvTag"> -1: 服务端请求关闭,如延时关闭 </param>
    /// <param name="pvTagData"> (Pointer) </param>
    function PostWSASendRequest(buf: Pointer; len: Cardinal; pvBufReleaseType:
        TDataReleaseType; pvTag: Integer = 0; pvTagData: Pointer = nil): Boolean;
        overload;

    /// <summary>
    ///   设置当前的接收线程信息
    /// </summary>
    procedure SetRecvWorkerHint(pvHintStr: String); overload;
    procedure SetRecvWorkerHint(pvFmtMsg: string; const args: array of const);
        overload;

    property Active: Boolean read FActive;

    property Data: Pointer read FData write FData;

    property DebugInfo: string read GetDebugInfo write SetDebugInfo;


    /// <summary>
    ///  连接时进行 +1
    /// </summary>
    property ContextDNA: Integer read FContextDNA;
    property CurrRecvRequest: TIocpRecvRequest read FCurrRecvRequest;
    property DisconnectedReason: String read FDisconnectedReason;

    /// <summary>
    ///   最后交互数据的时间点
    /// </summary>
    property LastActivity: Cardinal read FLastActivity;

    /// <summary>
    ///   手动投递PostRecv请求, 处理完接收请求收不自动投递接收请求(默认为false)
    /// </summary>
    property ManulPostWSARecvRequest: Boolean read FManulPostWSARecvRequest write
        FManulPostWSARecvRequest;

    property Owner: TDiocpTcpServer read FOwner write SetOwner;

    property RawSocket: TRawSocket read FRawSocket;

    property RemoteAddr: String read FRemoteAddr;

    property RemotePort: Integer read FRemotePort;

    /// <summary>
    ///   请注意
    ///   SocketHandle非真正的Socket句柄，如果需要访问真正的Socket句柄可以访问RawSocket.Handle
    /// </summary>
    property SocketHandle: TSocket read FSocketHandle;
    property SocketState: TSocketState read FSocketState;
    property TagStr: String read FTagStr write FTagStr;
  end;



  /// <summary>
  ///   WSARecv io request
  /// </summary>
  TIocpRecvRequest = class(TIocpRequest)
  private
    FAlive:Boolean;
    __debugFlag : Integer;
    FCounter:Integer;
    FDebugInfo:String;
    FInnerBuffer: diocp_winapi_winsock2.TWsaBuf;
    FRecvBuffer: diocp_winapi_winsock2.TWsaBuf;
    FRecvdFlag: Cardinal;
    FOwner: TDiocpTcpServer;
    FClientContext:TIocpClientContext;
    /// <summary>
    ///   归还释放
    /// </summary>
    procedure ReleaseBack;
  protected
    /// <summary>
    ///   iocp reply request, run in iocp thread
    /// </summary>
    procedure HandleResponse; override;

    procedure ResponseDone; override;
  public
    /// <summary>
    ///   post recv request to iocp queue
    /// </summary>
    function PostRecvRequest: Boolean; overload;

    /// <summary>
    ///
    /// </summary>
    function PostRecvRequest(pvBuffer:PAnsiChar; len:Cardinal): Boolean; overload;

  public
    constructor Create;
    destructor Destroy; override;
  end;


  TIocpSendRequestClass = class of TIocpSendRequest;
  /// <summary>
  ///   WSASend io request
  /// </summary>
  TIocpSendRequest = class(TIocpRequest)
  private
    FLastMsg : String;
    FSendBufferReleaseType: TDataReleaseType;
    
    FMaxSize:Integer;
    
    // for singlelinked
    FNext:TIocpSendRequest;

    FIsBusying:Boolean;

    FAlive: Boolean;

    FBytesSize:Cardinal;

    // send buf record
    FWSABuf:TWsaBuf;


    FBuf:Pointer;
    FLen:Cardinal;

    FOwner: TDiocpTcpServer;

    procedure CheckClearSendBuffer();
    
    function GetWSABuf: PWsaBuf;
 protected
    FClientContext:TIocpClientContext;

    FOnDataRequestCompleted: TOnDataRequestCompleted;

    procedure UnBindingSendBuffer();
  protected
    /// 0:none, 1:succ, 2:completed, 3: has err, 4:owner is off
    FReponseState:Byte;
    
    /// <summary>
    ///   post send
    /// </summary>
    function ExecuteSend: Integer; virtual;
  protected
    /// <summary>
    ///   iocp reply request, run in iocp thread
    /// </summary>
    procedure HandleResponse; override;


    procedure ResponseDone; override;

    /// <summary>
    ///   give back to sendRequest ObjectPool
    /// </summary>
    procedure DoCleanUp;virtual;


    function GetStateINfo: String; override;
    

    /// <summary>
    ///   投递发送的数据到IOCP请求队列(WSASend)
    /// </summary>
    /// <returns>
    ///   发送失败返回False, 并请求断开连接
    /// </returns>
    /// <param name="buf"> (Pointer) </param>
    /// <param name="len"> (Cardinal) </param>
    function InnerPostRequest(buf: Pointer; len: Cardinal): Boolean;


  public
    constructor Create; virtual;

    destructor Destroy; override;

    /// <summary>
    ///   set buf inneed to send
    /// </summary>
    procedure SetBuffer(buf: Pointer; len: Cardinal; pvBufReleaseType: TDataReleaseType); overload;

    /// <summary>
    ///   set buf inneed to send
    /// </summary>
    procedure SetBuffer(buf: Pointer; len: Cardinal; pvCopyBuf: Boolean = true); overload;

    property ClientContext: TIocpClientContext read FClientContext;

    property Owner: TDiocpTcpServer read FOwner;

    /// <summary>
    ///   获取最后一次操作的Buff信息
    /// </summary>
    property WSABuf: PWsaBuf read GetWSABuf;

    

    

    /// <summary>
    ///   on entire buf send completed
    /// </summary>
    property OnDataRequestCompleted: TOnDataRequestCompleted read FOnDataRequestCompleted write FOnDataRequestCompleted;
  end;

  TIocpDisconnectExRequest = class(TIocpRequest)
  private
    {$IFDEF WRITE_LOG}
    FOwner: TDiocpTcpServer;
    {$ENDIF}

    FContext:TIocpClientContext;

  protected
    function PostRequest: Boolean;

    /// <summary>
    ///   directly post request,
    /// </summary>
    function DirectlyPost: Boolean;
  end;


  /// <summary>
  ///   acceptEx request
  /// </summary>
  TIocpAcceptExRequest = class(TIocpRequest)
  private
    /// <summary>
    ///   acceptEx lpOutBuffer[in]
    ///     A pointer to a buffer that receives the first block of data sent on a new connection,
    ///       the local address of the server, and the remote address of the client.
    ///       The receive data is written to the first part of the buffer starting at offset zero,
    ///       while the addresses are written to the latter part of the buffer.
    ///       This parameter must be specified.
    /// </summary>
    FAcceptBuffer: array [0.. 127] of byte;

    //FAcceptBufferV4: array [0.. (SizeOf(TSockAddrIn) + 16) * 2 - 1] of byte;

    FOwner: TDiocpTcpServer;
    FAcceptorMgr:TIocpAcceptorMgr;

    FClientContext:TIocpClientContext;
    /// <summary>
    ///   get socket peer info on acceptEx reponse
    /// </summary>
    procedure GetPeerINfo;
  protected
    function PostRequest: Boolean;

  protected
    procedure HandleResponse; override;

    procedure ResponseDone; override;

  public
    constructor Create(AOwner: TDiocpTcpServer);
  end;

  /// <summary>
  ///   manager acceptEx request
  /// </summary>
  TIocpAcceptorMgr = class(TObject)
  private
    FOwner: TDiocpTcpServer;

    FCount: Integer;

    // sendRequest pool
    FAcceptExRequestPool: TBaseQueue;
    // clientContext pool
    FContextPool: TBaseQueue;  

    FListenSocket: TRawSocket;
  protected
    FClientContextClass: TIocpClientContextClass;
    /// <summary>
    ///    获取一个连接对象，如果对象池中没有，则会创建一个新的实例
    /// </summary>
    function GetClientContext: TIocpClientContext;
    /// <summary>
    ///   释放连接对象，归还到对象池
    /// </summary>
    function ReleaseClientContext(pvObject:TIocpClientContext): Boolean;
  public
    constructor Create(AOwner: TDiocpTcpServer);

    destructor Destroy; override;

    function GetRequestObject: TIocpAcceptExRequest;

    procedure ReleaseRequestObject(pvRequest:TIocpAcceptExRequest);

    /// <summary>
    ///   检测是否需要投递AcceptEx
    /// </summary>
    procedure PostAcceptExRequest(pvNum: Integer); overload;
    /// <summary>
    ///   检测是否需要投递AcceptEx
    /// </summary>
    procedure PostAcceptExRequest; overload;
    procedure RegisterContextClass(pvContextClass: TIocpClientContextClass);

    /// <summary>
    ///   等待所有连接关闭
    /// </summary>
    function WaitForCancel(pvTimeOut: Cardinal): Boolean;

    procedure ClearObjects;

    property ListenSocket: TRawSocket read FListenSocket;



  end;

  /// <summary>
  ///   iocp的数据监控中心
  /// </summary>
  TIocpDataMonitor = class(TObject)
  private
    // 记录开始时间点
    FLastSpeedTick : Cardinal;
    
    // 记录开始时间点_数据
    FLastSpeed_WSASendResponse: Int64;
    FLastSpeed_WSARecvResponse: Int64;

    // 已发送字节
    FLastSpeed_WSASentSize    : Int64;
    // 已接收字节
    FLastSpeed_RecvSize       : Int64;

    // 速度信息
    FSpeed_WSASendResponse    : Int64;
    FSpeed_WSARecvResponse    : Int64;
    FSpeed_WSASentSize        : Int64;
    FSpeed_WSARecvSize        : Int64;

    // 最高在线数量
    FMaxOnlineCount:Integer;

    FSentSize:Int64;
    FRecvSize:Int64;
    FPostWSASendSize: Int64;

    FHandleCreateCounter:Integer;
    FHandleDestroyCounter:Integer;

    FContextCreateCounter: Integer;
    FContextOutCounter:Integer;
    FContextReturnCounter:Integer;

    FPushSendQueueCounter: Integer;
    FResponseSendObjectCounter:Integer;

    FSendRequestCreateCounter: Integer;
    FSendRequestOutCounter:Integer;
    FSendRequestReturnCounter:Integer;
    FSendRequestAbortCounter :Integer;

    FRecvRequestCreateCounter: Integer;
    FRecvRequestReturnCounter:Integer;
    FRecvRequestOutCounter:Integer;

    FPostWSASendCounter:Integer;
    FResponseWSASendCounter:Integer;

    FPostWSARecvCounter:Integer;
    FResponseWSARecvCounter:Integer;

    FAcceptExObjectCounter: Integer;
    FPostWSAAcceptExCounter:Integer;
    FResponseWSAAcceptExCounter:Integer;

    FLocker: TCriticalSection;
    FPostSendObjectCounter: Integer;

    procedure IncSentSize(pvSize:Cardinal);
    procedure incPostWSASendSize(pvSize:Cardinal);
    procedure incRecvdSize(pvSize:Cardinal);

    procedure incPostWSASendCounter();
    procedure IncResponseWSASendCounter;

    procedure IncPostWSARecvCounter;
    procedure IncResponseWSARecvCounter;

    procedure IncRecvRequestCreateCounter;
    procedure IncRecvRequestOutCounter;
    procedure IncRecvRequestReturnCounter;





    procedure IncAcceptExObjectCounter;

    procedure incPushSendQueueCounter;
    procedure incPostSendObjectCounter();
    procedure incResponseSendObjectCounter();
    {$IFDEF SOCKET_REUSE}
    procedure incHandleCreateCounter;
    procedure incHandleDestroyCounter;
    {$ENDIF}
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;

    /// <summary>
    ///  开始统计速度
    ///  记录当前信息
    /// </summary>
    procedure SpeedCalcuStart;

    /// <summary>
    ///   统计数据，计算时间信息
    /// </summary>
    procedure SpeedCalcuEnd;

    /// <summary>
    ///   计算最高在线数量
    /// </summary>
    procedure CalcuMaxOnlineCount(pvOnlineCount:Integer);

    property AcceptExObjectCounter: Integer read FAcceptExObjectCounter;
    property ContextCreateCounter: Integer read FContextCreateCounter;
    property ContextOutCounter: Integer read FContextOutCounter;
    property ContextReturnCounter: Integer read FContextReturnCounter;
    property HandleCreateCounter: Integer read FHandleCreateCounter;
    property HandleDestroyCounter: Integer read FHandleDestroyCounter;
    property Locker: TCriticalSection read FLocker;
    property MaxOnlineCount: Integer read FMaxOnlineCount;
    property PushSendQueueCounter: Integer read FPushSendQueueCounter;
    property PostSendObjectCounter: Integer read FPostSendObjectCounter;
    property ResponseSendObjectCounter: Integer read FResponseSendObjectCounter;

    property PostWSAAcceptExCounter: Integer read FPostWSAAcceptExCounter;
    property PostWSARecvCounter: Integer read FPostWSARecvCounter;
    property PostWSASendCounter: Integer read FPostWSASendCounter;


    property PostWSASendSize: Int64 read FPostWSASendSize;
    property RecvRequestCreateCounter: Integer read FRecvRequestCreateCounter;
    property RecvRequestOutCounter: Integer read FRecvRequestOutCounter;
    property RecvRequestReturnCounter: Integer read FRecvRequestReturnCounter;
    property RecvSize: Int64 read FRecvSize;

    property ResponseWSAAcceptExCounter: Integer read FResponseWSAAcceptExCounter;
    property ResponseWSARecvCounter: Integer read FResponseWSARecvCounter;
    property ResponseWSASendCounter: Integer read FResponseWSASendCounter;
    property SendRequestAbortCounter: Integer read FSendRequestAbortCounter;
    property SendRequestCreateCounter: Integer read FSendRequestCreateCounter;
    property SendRequestOutCounter: Integer read FSendRequestOutCounter;
    property SendRequestReturnCounter: Integer read FSendRequestReturnCounter;
    property SentSize: Int64 read FSentSize;
    property Speed_WSARecvResponse: Int64 read FSpeed_WSARecvResponse;
    property Speed_WSASendResponse: Int64 read FSpeed_WSASendResponse;
  end;

  {$IF RTLVersion>22}
  // thanks: 麦子仲肥19183455
  //  vcl for win64 （64位平台下，控件可用)
  [ComponentPlatformsAttribute(pidWin32 or pidWin64)]
  {$IFEND}

  TDiocpTcpServer = class(TComponent)
  private
    FListeners: TDiocpListeners;

    FDefaultListener:TDiocpListener;

    FDebugStrings:TStrings;

    FContextDNA : Integer;
    
    FLogger: TSafeLogger;

    FMaxSendingQueueSize:Integer;

    FIsDestroying :Boolean;
    FWSARecvBufferSize: cardinal;
    procedure SetWSARecvBufferSize(const Value: cardinal);

    function IsDestroying: Boolean;
    function LogCanWrite: Boolean;

    function RequestContextDNA:Integer;
    
  protected
    FIocpSendRequestClass:TIocpSendRequestClass;

    procedure SetName(const NewName: TComponentName); override;



    /// <summary>
    ///   当创建新的连接对象时会调用的函数
    ///   可以在这里面做一些初始化
    /// </summary>
    procedure OnCreateClientContext(const context: TIocpClientContext); virtual;

    /// <summary>
    ///   添加到在先列表中
    /// </summary>
    procedure AddToOnlineList(pvObject:TIocpClientContext);

    /// <summary>
    ///   从在线列表中移除
    /// </summary>
    procedure RemoveFromOnOnlineList(pvObject:TIocpClientContext); virtual;
  private
    // sendRequest pool
    FSendRequestPool: TBaseQueue;

    FRecvRequestPool: TBaseQueue;

    FClientContextClass: TIocpClientContextClass;

    // extend data
    FDataPtr: Pointer;

    /// data record
    FDataMoniter: TIocpDataMonitor;

    FActive: Boolean;
    FConnectedCount: Integer;
    FDefaultListenAddress: String;

    FIocpEngine: TIocpEngine;

    FKeepAlive: Boolean;
    FNoDelayOption: Boolean;

    FOnAfterOpen: TNotifyEvent;
    FOnContextConnected: TContextNotifyEvent;
    FOnContextDisconnected: TContextNotifyEvent;


    FOnDataReceived: TOnDataReceived;


    FOnContextError: TOnContextError;
    FOnContextAccept: TOnContextAcceptEvent;
    FOnSendBufferCompleted: TOnBufferEvent;
    FOnSendRequestResponse: TOnSendRequestResponse;

    FPort: Integer;
    FUseObjectPool: Boolean;

    procedure DoClientContextError(pvClientContext: TIocpClientContext;
        pvErrorCode: Integer);
    function GetWorkerCount: Integer;

    procedure SetWorkerCount(const Value: Integer);

    procedure SetActive(pvActive:Boolean);


    procedure DoReceiveData(pvIocpClientContext:TIocpClientContext;
        pvRequest:TIocpRecvRequest);
  protected
    FLocker:TIocpLocker;

    /// <summary>
    ///   维护的在线列表
    /// </summary>
    FOnlineContextList : TDHashTable;


    /// <summary>
    ///   获取一个发送请求对象(对象池)
    /// </summary>
    function GetSendRequest: TIocpSendRequest;

    /// <summary>
    ///   获取一个接收请求
    /// </summary>
    function GetRecvRequest: TIocpRecvRequest;

    function ReleaseRecvRequest(pvObject: TIocpRecvRequest): Boolean;

    /// <summary>
    ///   归还一个发送请求对象(对象池)
    /// </summary>
    function ReleaseSendRequest(pvObject:TIocpSendRequest): Boolean;

    procedure DoAfterOpen; virtual;

    procedure DoAfterClose; virtual;

  private
    /// <summary>
    ///   在投递的AcceptEx请求响应时中调用
    /// </summary>
    /// <param name="pvRequest"> 响应的请求 </param>
    procedure DoAcceptExResponse(pvRequest: TIocpAcceptExRequest);

    function GetClientCount: Integer;

    procedure OnIocpException(pvRequest:TIocpRequest; E:Exception);

    procedure DoSendBufferCompletedEvent(pvContext: TIocpClientContext; pvBuffer:
        Pointer; len: Cardinal; pvBufferTag, pvErrorCode: Integer);
    procedure InnerAddToDebugStrings(pvMsg:String);
  public

    /// <summary>
    ///   超时检测, 如果超过Timeout指定的时间还没有任何数据交换数据记录，
    ///     就进行关闭连接
    ///   使用循环检测，如果你有好的方案，欢迎提交您的宝贵意见
    /// </summary>
    procedure KickOut(pvTimeOut:Cardinal = 60000);

    /// <summary>
    ///   获取逻辑超过3秒未完成的连接信息
    /// </summary>
    function GetContextWorkingInfo(pvTimeOut:Cardinal = 3000): String;

    procedure LogMessage(pvMsg: string; pvMsgType: string = ''; pvLevel: TLogLevel
        = lgvMessage); overload;

    procedure LogMessage(pvMsg: string; const args: array of const; pvMsgType:
        string = ''; pvLevel: TLogLevel = lgvMessage); overload;


    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// <summary>
    ///   设置允许每个连接允许最大发送队列，超过后不允许再进行投递
    /// </summary>
    procedure SetMaxSendingQueueSize(pvSize:Integer);


    procedure AddDebugStrings(pvDebugInfo: String; pvAddTimePre: Boolean = true);

    /// <summary>
    ///   根据SocketHandle在在线列表中查找对应的Context实例
    /// </summary>
    function FindContext(pvSocketHandle:TSocket): TIocpClientContext;

    procedure RegisterContextClass(pvContextClass: TIocpClientContextClass);

    procedure RegisterSendRequestClass(pvClass: TIocpSendRequestClass);

    /// <summary>
    ///   创建数据监控中心实例
    /// </summary>
    procedure CreateDataMonitor;


    /// <summary>
    ///   check clientContext object is valid.
    /// </summary>
    function CheckClientContextValid(const pvClientContext: TIocpClientContext):
        Boolean;

    /// <summary>
    ///   断开所有在线连接
    /// </summary>
    procedure DisconnectAll;

    /// <summary>
    ///   等待所有连接关闭
    /// </summary>
    function WaitForContext(pvTimeOut: Cardinal): Boolean;


    /// <summary>
    ///   get online client list
    /// </summary>
    procedure GetOnlineContextList(pvList:TList);

    /// <summary>
    ///   stop and wait all workers down
    /// </summary>
    procedure SafeStop;



    procedure Open;

    procedure Close;
    function GetDebugString: String;
    function GetPrintDebugInfo: string;

    /// <summary>
    ///   
    /// </summary>
    function GetStateInfo: String;



    /// <summary>
    ///   client connections counter
    /// </summary>
    property ClientCount: Integer read GetClientCount;

    property ConnectedCount: Integer read FConnectedCount;


    property DataMoniter: TIocpDataMonitor read FDataMoniter;
    property IocpEngine: TIocpEngine read FIocpEngine;

    /// <summary>
    ///   set socket Keep alive option when acceptex
    /// </summary>
    property KeepAlive: Boolean read FKeepAlive write FKeepAlive;

    /// <summary>
    ///   extend data
    /// </summary>
    property DataPtr: Pointer read FDataPtr write FDataPtr;
    property Listeners: TDiocpListeners read FListeners;

    //property IocpAcceptorMgr: TIocpAcceptorMgr read FIocpAcceptorMgr;

    /// <summary>
    ///   SERVER Locker
    /// </summary>
    property Locker: TIocpLocker read FLocker;


    property Logger: TSafeLogger read FLogger;


  published

    /// <summary>
    ///   服务开启/关闭
    /// </summary>
    property Active: Boolean read FActive write SetActive;

    /// <summary>
    ///   最大的待发送缓存队列, 服务开启时不允许设定
    /// </summary>
    property MaxSendingQueueSize: Integer read FMaxSendingQueueSize write SetMaxSendingQueueSize;

    /// <summary>
    ///   当连接断开时触发事件
    ///     当TDiocpTcpServer.Active为False时不进行触发
    ///     在Iocp工作线程中触发
    /// </summary>
    property OnContextDisconnected: TContextNotifyEvent read FOnContextDisconnected
        write FOnContextDisconnected;

    /// <summary>
    ///   当连接建立成功时触发事件
    ///     当TDiocpTcpServer.Active为False时不进行触发
    ///     在Iocp工作线程中触发
    /// </summary>
    property OnContextConnected: TContextNotifyEvent read FOnContextConnected
        write FOnContextConnected;

    /// <summary>
    ///   当接受连接时触发事件
    ///     当TDiocpTcpServer.Active为False时不进行触发
    ///     在Iocp工作线程中触发
    /// </summary>
    property OnContextAccept: TOnContextAcceptEvent read FOnContextAccept write
        FOnContextAccept;

    /// <summary>
    ///  响应发送完成事件
    /// </summary>
    property OnSendRequestResponse: TOnSendRequestResponse read
        FOnSendRequestResponse write FOnSendRequestResponse;

    /// <summary>
    ///   默认侦听地址, 设置后，指侦听某个IP
    /// </summary>
    property DefaultListenAddress: String read FDefaultListenAddress write
        FDefaultListenAddress;

    /// <summary>
    ///   发送的Buffer已经完成
    /// </summary>
    property OnSendBufferCompleted: TOnBufferEvent read FOnSendBufferCompleted
        write FOnSendBufferCompleted;

    /// <summary>
    ///   开启后执行的过程
    /// </summary>
    property OnAfterOpen: TNotifyEvent read FOnAfterOpen write FOnAfterOpen;

    /// <summary>
    ///   NoDelay属性(默认是false)
    ///   设置为true是会禁用Socket的NoDelay属性(禁用nagle算法)
    ///   nagle算法会造成200ms左右的延时
    ///   开启时运行时改变改该属性，不会重新设置已经建立的连接(对以后建立的连接有效)
    ///
    ///   为了减少网络拥塞而设计的，它会等待足够的数据才发送出去，如果没有足够的数据，就会等待约200ms（内部计时器超时触发）后发送出去
    /// </summary>
    property NoDelayOption: Boolean read FNoDelayOption write FNoDelayOption;
    
    /// <summary>
    ///   默认侦听的端口
    /// </summary>
    property Port: Integer read FPort write FPort;

    /// <summary>
    ///   是否使用对象池
    /// </summary>
    property UseObjectPool: Boolean read FUseObjectPool write FUseObjectPool;






    /// <summary>
    ///   iocp工作线程
    ///    为0时默认为 cpu count * 2 -1
    /// </summary>
    property WorkerCount: Integer read GetWorkerCount write SetWorkerCount;


    /// <summary>
    ///   post wsaRecv request block size
    /// </summary>
    property WSARecvBufferSize: cardinal read FWSARecvBufferSize write
        SetWSARecvBufferSize;



    /// <summary>
    ///  on work error
    ///    occur in post request methods or iocp worker thread
    /// </summary>
    property OnContextError: TOnContextError read FOnContextError write
        FOnContextError;



    /// <summary>
    ///  on clientcontext received data
    ///    called by iocp worker thread
    /// </summary>
    property OnDataReceived: TOnDataReceived read FOnDataReceived write
        FOnDataReceived;










  end;



var
  __svrLogger:TSafeLogger;


/// <summary>
///   注册服务使用的SafeLogger
/// </summary>
procedure RegisterDiocpSvrLogger(pvLogger:TSafeLogger);



implementation

uses
  DateUtils;


var
  __startTime:TDateTime;
  __innerLogger:TSafeLogger;




/// <summary>
///   计算两个TickCount时间差，避免超出49天后，溢出
///      感谢 [佛山]沧海一笑  7041779 提供
///      copy自 qsl代码 
/// </summary>
function tick_diff(tick_start, tick_end: Cardinal): Cardinal;
begin
  if tick_end >= tick_start then
    result := tick_end - tick_start
  else
    result := High(Cardinal) - tick_start + tick_end;
end;



function GetRunTimeINfo: String;
var
  lvMSec, lvRemain:Int64;
  lvDay, lvHour, lvMin, lvSec:Integer;
begin
  lvMSec := MilliSecondsBetween(Now(), __startTime);
  lvDay := Trunc(lvMSec / MSecsPerDay);
  lvRemain := lvMSec mod MSecsPerDay;

  lvHour := Trunc(lvRemain / (MSecsPerSec * 60 * 60));
  lvRemain := lvRemain mod (MSecsPerSec * 60 * 60);

  lvMin := Trunc(lvRemain / (MSecsPerSec * 60));
  lvRemain := lvRemain mod (MSecsPerSec * 60);

  lvSec := Trunc(lvRemain / (MSecsPerSec));

  if lvDay > 0 then
    Result := Result + IntToStr(lvDay) + ' d ';

  if lvHour > 0 then
    Result := Result + IntToStr(lvHour) + ' h ';

  if lvMin > 0 then
    Result := Result + IntToStr(lvMin) + ' m ';

  if lvSec > 0 then
    Result := Result + IntToStr(lvSec) + ' s ';
end;


///TRunTimeINfoTools
function TransByteSize(pvByte: Int64): String;
var
  lvTB, lvGB, lvMB, lvKB:Word;
  lvRemain:Int64;
begin
  lvRemain := pvByte;

  lvTB := Trunc(lvRemain/BytePerGB/1024);
  //lvRemain := pvByte - (lvTB * BytePerGB * 1024);
  
  lvGB := Trunc(lvRemain/BytePerGB);

  lvGB := lvGB mod 1024;      // trunc TB

  lvRemain := lvRemain mod BytePerGB;

  lvMB := Trunc(lvRemain/BytePerMB);
  lvRemain := lvRemain mod BytePerMB;

  lvKB := Trunc(lvRemain/BytePerKB);
  lvRemain := lvRemain mod BytePerKB;
  Result := Format('%d TB, %d GB, %d MB, %d KB, %d B', [lvTB, lvGB, lvMB, lvKB, lvRemain]);
end;


  

/// compare target, cmp_val same set target = new_val
/// return old value
function lock_cmp_exchange(cmp_val, new_val: Boolean; var target: Boolean): Boolean; overload;
asm
{$ifdef win32}
  lock cmpxchg [ecx], dl
{$else}
.noframe
  mov rax, rcx
  lock cmpxchg [r8], dl
{$endif}
end;

procedure RegisterDiocpSvrLogger(pvLogger:TSafeLogger);
begin
  if __svrLogger <> pvLogger then
  begin
    __svrLogger := pvLogger;
    if __innerLogger <> nil then
    begin
      __innerLogger.Free;
      __innerLogger := nil;
    end;
  end;
end;


procedure TIocpClientContext.InnerCloseContext;
var
  s:String;
begin
  if FOwner = nil then
  begin
    s := FDebugStrings.Text;
    s := Format('当前对象已经失去Owner:%s',
       [s]);
    sfLogger.logMessage(s, 'core_debug', lgvWarning);
    Assert(FOwner <> nil);
  end;


{$IFDEF WRITE_LOG}
  if FReferenceCounter <> 0 then
    FOwner.LogMessage('InnerCloseContext FReferenceCounter:%d',
      [FReferenceCounter], CORE_LOG_FILE, lgvError);

  if not FActive then
  begin
    FOwner.LogMessage('InnerCloseContext FActive is false', CORE_LOG_FILE, lgvError);
    exit;
  end;
{$ENDIF}
  if not FActive then exit;

//  Assert(FReferenceCounter = 0);
//  Assert(FActive);
  try
    FActive := false;
  {$IFDEF SOCKET_REUSE}

  {$ELSE}
    FRawSocket.Close;
  {$ENDIF}

    CheckReleaseRes;

    try
      if FOwner.Active then
      begin
        if Assigned(FOwner.FOnContextDisconnected) then
        begin
          FOwner.FOnContextDisconnected(Self);
        end;
        DoDisconnected;
      end;
    except
      on e:Exception do
      begin
        sfLogger.LogMessage(
          Format('InnerCloseContext:%s', [e.Message]), CORE_LOG_FILE);
      end;
    end;
  finally
    {$IFDEF DIOCP_DEBUG}
    InnerLock;
    AddDebugString(Format('#-(%d):Disconnected', [FContextDNA]));
    InnerUnLock;

    {$ENDIF}

    FOwner.RemoveFromOnOnlineList(Self);

    ReleaseBack();

  end;

end;

procedure TIocpClientContext.InnerLock;
begin
  //FContextLocker.lock();
  SpinLock(FInnerLockerFlag);
end;

procedure TIocpClientContext.InnerUnLock;
begin
  //FContextLocker.unLock;
  SpinUnLock(FInnerLockerFlag);
end;


procedure TIocpClientContext.lock;
begin
  FContextLocker.lock();
end;

function TIocpClientContext.LockContext(pvDebugInfo: string; pvObj: TObject):
    Boolean;
begin
  Result := IncReferenceCounter(pvDebugInfo, pvObj);
end;

procedure TIocpClientContext.unLockContext(pvDebugInfo: string; pvObj: TObject);
begin
  if Self = nil then
  begin
    Assert(Self<> nil);
  end;
  DecReferenceCounter(pvDebugInfo, pvObj);
end;


procedure TIocpClientContext.BeginBusy;
begin
  InterlockedIncrement(FBusingCounter);
end;

procedure TIocpClientContext.CheckNextSendRequest;
var
  lvRequest:TIocpSendRequest;
  r:Integer;
begin
  Assert(FOwner <> nil);

  InnerLock;
  try
    lvRequest := TIocpSendRequest(FSendRequestLink.Pop);
    if lvRequest = nil then
    begin
      FSending := false;
      exit;
    end;
  finally
    InnerUnLock;
  end;

  if lvRequest <> nil then
  begin   
    FcurrSendRequest := lvRequest;
    r := lvRequest.ExecuteSend;
    if r = 0 then
    begin
      if (FOwner.FDataMoniter <> nil) then
      begin
        FOwner.FDataMoniter.incPostSendObjectCounter;
      end;
    end else
    begin
      FCurrSendRequest := nil;

      /// 取消请求
      lvRequest.CancelRequest;

      if r = -2 then
      begin
        RequestDisconnect(strWSACloseRequestEx, lvRequest);
      end else
      begin
       /// 踢出连接
        RequestDisconnect(Format(strFuncFail,
          [self.SocketHandle,'CheckNextSendRequest::lvRequest.ExecuteSend', lvRequest.FLastMsg]), lvRequest);
      end;
      FOwner.ReleaseSendRequest(lvRequest);
    end;
  end;
end;

procedure TIocpClientContext.CheckReleaseRes;
var
  lvRequest:TIocpSendRequest;
begin
  while true do
  begin
    lvRequest :=TIocpSendRequest(FSendRequestLink.Pop);
    if lvRequest <> nil then
    begin
      if (FOwner.FDataMoniter <> nil) then
      begin
        InterlockedIncrement(FOwner.FDataMoniter.FSendRequestAbortCounter);
      end;

      lvRequest.CancelRequest;
      FOwner.ReleaseSendRequest(lvRequest);
    end else
    begin
      Break;
    end;
  end;
end;

constructor TIocpClientContext.Create;
begin
  inherited Create;
  FDebugStrings := TStringList.Create;
  FReferenceCounter := 0;
  FContextLocker := TIocpLocker.Create('contextLocker');
  FAlive := False;
  FRawSocket := TRawSocket.Create();
  FActive := false;

  FSendRequestLink := TIocpRequestSingleLink.Create(100);
//  FRecvRequest := TIocpRecvRequest.Create;
//  FRecvRequest.FClientContext := self;

  {$IFDEF SOCKET_REUSE}
  FDisconnectExRequest:=TIocpDisconnectExRequest.Create;
  FDisconnectExRequest.FContext := Self;
  FDisconnectExRequest.OnResponse := OnDisconnectExResponse;
  {$ENDIF}
end;

function TIocpClientContext.IncReferenceCounter(pvDebugInfo: string; pvObj:
    TObject): Boolean;
begin
  InnerLock;
  try
    if (not Active) or FRequestDisconnect then
    begin
      Result := false;
    end else
    begin
      Assert(FReferenceCounter >= 0);
      
      Inc(FReferenceCounter);
      {$IFDEF DIOCP_DEBUG}
      AddDebugString(Format('+(%d):%d,%s', [FReferenceCounter, IntPtr(pvObj), pvDebugInfo]));
      {$ENDIF}

      Result := true;
    end;
  finally
    InnerUnLock;
  end;
end;


procedure TIocpClientContext.AddDebugString(pvString:string);
begin
  if __free_flag = FREE_FLAG then
  begin
    Assert(__free_flag <> FREE_FLAG);
  end;
  FDebugStrings.Add(pvString);
  if FDebugStrings.Count > 40 then FDebugStrings.Delete(0);
end;

function TIocpClientContext.DecReferenceCounter(pvDebugInfo: string; pvObj:
    TObject): Integer;
var
  lvCloseContext:Boolean;
begin
  if __free_flag = FREE_FLAG then
  begin
    Assert(__free_flag <> FREE_FLAG);
  end;
  lvCloseContext := false;
  if self = nil then
  begin
    Assert(False);
  end;
  InnerLock;
  try
//    {$IFDEF WRITE_LOG}
//    FOwner.logMessage(Format('(%s:%d[%d]):%s', [self.RemoteAddr, self.RemotePort, self.SocketHandle, pvDebugInfo]),
//        strRequestDisconnectFileID, lgvDebug);
//    {$ENDIF}
    Dec(FReferenceCounter);
    Result := FReferenceCounter;
    {$IFDEF DIOCP_DEBUG}
    AddDebugString(Format('-(%d):%d,%s', [FReferenceCounter, IntPtr(pvObj), pvDebugInfo]));
    {$ENDIF}

    if FReferenceCounter < 0 then
    begin  // 小于0，不正常情况
      {$IFDEF DEBUG_ON}
      if IsDebugMode then
      begin
        FOwner.logMessage('TIocpClientContext.DecReferenceCounter:%d, DebugInfo:%s',
          [FReferenceCounter, FDebugStrings.Text], CORE_DEBUG_FILE, lgvError);
        Assert(FReferenceCounter >=0,Format('TIocpClientContext.DecReferenceCounter:%d, DebugInfo:%s',
          [FReferenceCounter, FDebugStrings.Text]));
      end else
      begin
        FOwner.logMessage('TIocpClientContext.DecReferenceCounter:%d, DebugInfo:%s',
            [FReferenceCounter, FDebugStrings.Text], CORE_DEBUG_FILE, lgvError);
      end;
      {$ENDIF}
      FReferenceCounter :=0;
    end;
    if FReferenceCounter = 0 then
      if FRequestDisconnect then lvCloseContext := true;
  finally
    InnerUnLock;
  end;

  if lvCloseContext then InnerCloseContext;
end;

procedure TIocpClientContext.DecReferenceCounterAndRequestDisconnect(
    pvDebugInfo: string; pvObj: TObject);
var
  lvCloseContext:Boolean;
begin
  lvCloseContext := false;

  InnerLock;
  try
    {$IFDEF WRITE_LOG}
      FOwner.logMessage(Format('(%s:%d[%d]):%s', [self.RemoteAddr, self.RemotePort, self.SocketHandle, pvDebugInfo]),
        strRequestDisconnectFileID, lgvDebug);
    {$ENDIF}

    FRequestDisconnect := true;
    Dec(FReferenceCounter);
  
    {$IFDEF DIOCP_DEBUG}
    AddDebugString(Format('-(%d):%d,%s', [FReferenceCounter, IntPtr(pvObj), pvDebugInfo]));
    {$ENDIF}

    if FReferenceCounter < 0 then
    begin
      {$IFDEF DEBUG_ON}
      if IsDebugMode then
      begin
        Assert(FReferenceCounter >=0);
      end else
      begin
        FOwner.logMessage('TIocpClientContext.DecReferenceCounterAndRequestDisconnect:%d, DebugInfo:%s',
            [FReferenceCounter, FDebugStrings.Text], CORE_DEBUG_FILE, lgvError);
      end;
      {$ENDIF}
      FReferenceCounter :=0;
    end;
    if FReferenceCounter = 0 then
      lvCloseContext := true;
    
  finally
    InnerUnLock;
  end;
  
  if lvCloseContext then InnerCloseContext;
end;

procedure TIocpClientContext.ReleaseBack;
begin
  // 归还到连接上下文池
  FAcceptorMgr.ReleaseClientContext(Self);
end;

function TIocpClientContext.ReleaseSendRequest(
  pvObject: TIocpSendRequest): Boolean;
begin
  Result := FOwner.ReleaseSendRequest(pvObject);
end;

procedure TIocpClientContext.RequestDisconnect(pvReason: string = ''; pvObj:
    TObject = nil);
var
  lvCloseContext:Boolean;
begin
  if not FActive then exit;

{$IFDEF WRITE_LOG}
  FOwner.logMessage(Format('(%s:%d[%d]):%s', [self.RemoteAddr, self.RemotePort, self.SocketHandle, pvReason]), strRequestDisconnectFileID, lgvDebug);
{$ENDIF}

  // 关闭请求
  FRequestClose := 1;

  InnerLock;
  try
    {$IFDEF DIOCP_DEBUG}
    if pvReason <> '' then
    begin
      AddDebugString(Format('*(%d):%d,%s', [FReferenceCounter, IntPtr(pvObj), pvReason]));
    end;
    {$ENDIF}
  
    {$IFDEF SOCKET_REUSE}
    lvCloseContext := False;
    if not FRequestDisconnect then
    begin
      FDisconnectedReason := pvReason;

      // cancel
      FRawSocket.ShutDown();
      FRawSocket.CancelIO;

      // post succ, in handleReponse Event do
      if not FDisconnectExRequest.PostRequest then
      begin      // post fail,
        FRawSocket.close;
        if FReferenceCounter = 0 then  lvCloseContext := true;    //      lvCloseContext := true;   //directly close
      end;
      FRequestDisconnect := True;
    end;
    {$ELSE}
    if not FRequestDisconnect then
    begin
      FDisconnectedReason := pvReason;
      FRequestDisconnect := True;
    end;
    lvCloseContext := False;
    if FReferenceCounter = 0 then  lvCloseContext := true;
    {$ENDIF}
  finally
    InnerUnLock;
  end;

  {$IFDEF SOCKET_REUSE}
  if lvCloseContext then InnerCloseContext;
  {$ELSE}
  if lvCloseContext then InnerCloseContext else
  begin
    FRawSocket.Close;
  end;
  {$ENDIF}
end;

destructor TIocpClientContext.Destroy;
begin
  if IsDebugMode then
  begin
    if FReferenceCounter <> 0 then
    begin
      Assert(FReferenceCounter = 0);
    end;

    if FSendRequestLink.Count > 0 then
    begin
      Assert(FSendRequestLink.Count = 0);
    end;
  end;

  FRawSocket.Close;
  FRawSocket.Free;


//  if FRecvRequest.Responding then
//  begin
//    // 正在响应，不进行释放
//    FRecvRequest.DestroyOnResponseEnd := true;
//  end else
//  begin
//    FRecvRequest.__debugFlag2 := -2;
//    FRecvRequest.FClientContext := nil;
//    FRecvRequest.Free;
//  end;
  
  if IsDebugMode then
  begin
    Assert(FSendRequestLink.Count = 0);
  end;

  {$IFDEF SOCKET_REUSE}
  FDisconnectExRequest.Free;
  {$ENDIF}

  FSendRequestLink.Free;
  FContextLocker.Free;
  FDebugStrings.Free;
  FDebugStrings := nil;
  __free_flag := FREE_FLAG;
  inherited Destroy;
end;

procedure TIocpClientContext.CheckThreadIn;
begin
  if FCheckThreadId <> 0 then
  begin
    //s := GetDebugString;
    raise Exception.CreateFmt('(%d,%d)当前对象已经被其他线程正在使用',
       [utils_strings.GetCurrentThreadID, FCheckThreadId]);
  end;
  FCheckThreadId := utils_strings.GetCurrentThreadID;
end;

procedure TIocpClientContext.CheckThreadOut;
begin
  FCheckThreadId := 0;
end;

function TIocpClientContext.CheckWorkingTick: Cardinal;
begin
  Result := 0;
  // 已经完成工作
  if FWorkerEndTick <> 0 then Exit;

  // 还没有开始工作
  if FWorkerStartTick = 0 then Exit;

  Result := tick_diff(FWorkerStartTick, GetTickCount);  
end;

procedure TIocpClientContext.DoCleanUp;
begin
  CheckThreadIn;
  try
    FLastActivity := 0;
    FRequestClose := 0;

    FOwner := nil;
    FRequestDisconnect := false;
    FManulPostWSARecvRequest := false;
    FSending := false;

    FWorkerEndTick := 0;
    FWorkerStartTick := 0;

    {$IFDEF DIOCP_DEBUG}
    InnerLock;
    AddDebugString(Format('-(%d):%d,%s', [FReferenceCounter, IntPtr(Self), '-----DoCleanUp-----']));
    InnerUnLock;
    {$ENDIF}
    if IsDebugMode then
    begin
      Assert(FReferenceCounter = 0, Format('TIocpClientContext.DoCleanUp::FReferenceCounter=%d', [FReferenceCounter]));
      Assert(not FActive, 'DoCleanUp::Context is active');
    end;
  finally
    CheckThreadOut;
  end;


//  if FActive then
//  begin
//    FRawSocket.close;
//    FActive := false;
//    CheckReleaseRes;
//  end;
end;

procedure TIocpClientContext.DoConnected;
begin
  FLastActivity := GetTickCount;

  //FContextLocker.lock('DoConnected');
  try
    FSocketHandle := MakeDiocpHandle;
    //  FRawSocket.SocketHandle;
    Assert(FOwner <> nil);
    if FActive then
    begin
      if IsDebugMode then
      begin
        Assert(not FActive);
      end;
      {$IFDEF WRITE_LOG}
       FOwner.logMessage(strDoConnectedError, [SocketHandle], CORE_DEBUG_FILE, lgvError);
      {$ENDIF}
    end else
    begin
      InterlockedIncrement(FOwner.FConnectedCount);

      FContextDNA := FOwner.RequestContextDNA;
      FActive := true;

      {$IFDEF DIOCP_DEBUG}
      InnerLock;
      AddDebugString(Format('#+(%d):Connected', [FContextDNA]));
      InnerUnLock;
      {$ENDIF}
      FOwner.AddToOnlineList(Self);

      if self.LockContext('onConnected', Self) then
      try
        try
          if Assigned(FOwner.FOnContextConnected) then
          begin
            FOwner.FOnContextConnected(Self);
          end;

          OnConnected();
        except
          on e:Exception do
          begin
            sfLogger.LogMessage(
              Format('DoConnected:%s', [e.Message]), CORE_LOG_FILE);
          end;
        end;

        PostWSARecvRequest;
      finally
        Self.UnLockContext('OnConnected', Self);
      end;
    end;
  finally
    //FContextLocker.unLock;
  end;
end;

procedure TIocpClientContext.DoDisconnect;
begin
  RequestDisconnect('DoDisconnect');
end;

procedure TIocpClientContext.DoDisconnected;
begin
  OnDisconnected;
end;

procedure TIocpClientContext.DoReceiveData(pvRecvRequest: TIocpRecvRequest);
begin
  try
    if FRequestClose = 1 then
    begin
      // 不再响应任何的接收数据请求
      Exit;
    end;
    
    BeginBusy;
    try
      FLastActivity := GetTickCount;

      OnRecvBuffer(pvRecvRequest.FRecvBuffer.buf,
        pvRecvRequest.FBytesTransferred,
        pvRecvRequest.FErrorCode);
      if FOwner <> nil then
        FOwner.doReceiveData(Self, pvRecvRequest);
    finally
      EndBusy;
    end;
  except
    on E:Exception do
    begin
      if FOwner <> nil then
      begin       
        FOwner.LogMessage(strOnRecvBufferException, [SocketHandle, e.Message], '异常', lgvError);

        FOwner.DoClientContextError(Self, -1);
      end else
      begin
        __svrLogger.logMessage(strOnRecvBufferException, [SocketHandle, e.Message], '异常', lgvError);
      end;
    end;
  end;
end;

procedure TIocpClientContext.DoSendBufferCompleted(pvBuffer: Pointer; len:
    Cardinal; pvBufferTag, pvErrorCode: Integer);
begin
  
end;

procedure TIocpClientContext.DoSendRequestCompleted(pvRequest:
    TIocpSendRequest);
begin
  ;
end;

procedure TIocpClientContext.DoSendRequestRespnonse(
  pvRequest: TIocpSendRequest);
begin
  FLastActivity := GetTickCount;
  
  if Assigned(FOwner.FOnSendRequestResponse) then
  begin
    FOwner.FOnSendRequestResponse(Self, pvRequest);
  end;
end;

procedure TIocpClientContext.EndBusy;
begin
  InterlockedDecrement(FBusingCounter);
end;

function TIocpClientContext.GetDebugInfo: string;
begin
  InnerLock;
  try
    if Length(FDebugInfo) > 0 then
      Result := Copy(FDebugInfo, 0, Length(FDebugInfo))
    else
      Result := '';
  finally
    InnerUnLock;
  end;
end;

function TIocpClientContext.GetSendQueueSize: Integer;
begin
  Result := FSendRequestLink.Count;
end;

function TIocpClientContext.GetSendRequest: TIocpSendRequest;
begin
  Result := FOwner.GetSendRequest;
  Assert(Result <> nil);
  Result.FClientContext := self;
end;


procedure TIocpClientContext.OnConnected;
begin
  
end;

procedure TIocpClientContext.OnDisconnected;
begin

end;


{$IFDEF SOCKET_REUSE}
procedure TIocpClientContext.OnDisconnectExResponse(pvObject:TObject);
var
  lvRequest:TIocpDisconnectExRequest;
begin
  if FActive then
  begin   // already connected
    lvRequest :=TIocpDisconnectExRequest(pvObject);
    if lvRequest.FErrorCode <> 0 then
    begin
      RawSocket.close;
      if (FOwner.FDataMoniter <> nil) then
        FOwner.FDataMoniter.incHandleDestroyCounter;
      DecReferenceCounter(
          Format('TIocpDisconnectExRequest.HandleResponse.Error, %d', [lvRequest.FErrorCode])
          , lvRequest
        );
    end else
    begin
      DecReferenceCounter(
          'TIocpDisconnectExRequest.HandleResponse', lvRequest
        );
    end;
  end else
  begin
    // not connected, onaccept allow is false
    FOwner.releaseClientContext(Self)
  end;
end;
{$ENDIF}


procedure TIocpClientContext.OnRecvBuffer(buf: Pointer; len: Cardinal; ErrCode:
    WORD);
begin
    
end;

procedure TIocpClientContext.PostNextSendRequest;
begin
  CheckNextSendRequest;
end;

function TIocpClientContext.InnerPostSendRequestAndCheckStart(
    pvSendRequest:TIocpSendRequest): Boolean;
var
  lvStart:Boolean;
begin
  lvStart := false;
  InnerLock;
  try
    Result := FSendRequestLink.Push(pvSendRequest);
    if Result then
    begin
      if (FOwner<> nil) and (FOwner.FDataMoniter <> nil) then
      begin
        FOwner.FDataMoniter.incPushSendQueueCounter;
      end;
      if not FSending then
      begin
        FSending := true;
        lvStart := true;  // start send work
      end;
    end;
  finally
    InnerUnLock;
  end;



  if lvStart then
  begin      // start send work

    CheckNextSendRequest;
  end;
end;


procedure TIocpClientContext.SetRecvWorkerHint(pvFmtMsg: string; const args:
    array of const);
begin
  SetRecvWorkerHint(Format(pvFmtMsg, args));
end;

procedure TIocpClientContext.PostWSACloseRequest;
begin
  if not FActive then exit;
  
  FRequestClose := 1;
  PostWSASendRequest(nil, 0, dtNone, -1);
  
end;

procedure TIocpClientContext.PostWSARecvRequest;
var
  lvRecvRequest:TIocpRecvRequest;
begin
  lvRecvRequest := FOwner.GetRecvRequest;
  lvRecvRequest.FClientContext := Self;
  if not lvRecvRequest.PostRecvRequest then
  begin
    lvRecvRequest.ReleaseBack;
  end;
end;



function TIocpClientContext.PostWSASendRequest(buf: Pointer; len: Cardinal;
    pvCopyBuf: Boolean = true; pvTag: Integer = 0; pvTagData: Pointer = nil):
    Boolean;
var
  lvBuf: PAnsiChar;
begin
  if len = 0 then raise Exception.Create('PostWSASendRequest::request buf is zero!');
  if pvCopyBuf then
  begin
    GetMem(lvBuf, len);
    Move(buf^, lvBuf^, len);
    Result := PostWSASendRequest(lvBuf, len, dtFreeMem, pvTag, pvTagData);
    if not Result then
    begin            //post fail
      FreeMem(lvBuf);
    end;
  end else
  begin
    lvBuf := buf;
    Result := PostWSASendRequest(lvBuf, len, dtNone, pvTag, pvTagData);
  end;

end;

function TIocpClientContext.PostWSASendRequest(buf: Pointer; len: Cardinal;
    pvBufReleaseType: TDataReleaseType; pvTag: Integer = 0; pvTagData: Pointer
    = nil): Boolean;
var
  lvRequest:TIocpSendRequest;
  s:String;
begin
  Result := false;
  if self.Active then
  begin
    if self.IncReferenceCounter('PostWSASendRequest', Self) then
    begin
      try
        lvRequest := GetSendRequest;
        lvRequest.SetBuffer(buf, len, pvBufReleaseType);
        lvRequest.Tag := pvTag;
        lvRequest.Data := pvTagData;
        Result := InnerPostSendRequestAndCheckStart(lvRequest);
        if not Result then
        begin
          /// Push Fail unbinding buf
          lvRequest.UnBindingSendBuffer;

          s := Format(strSendPushFail, [FSocketHandle, FSendRequestLink.Count, FSendRequestLink.MaxSize]);

          Self.RequestDisconnect(s,lvRequest);

          FOwner.ReleaseSendRequest(lvRequest);
        end;
      finally
        self.DecReferenceCounter('PostWSASendRequest', Self);
      end;
    end;
  end;
end;

procedure TIocpClientContext.RecordWorkerEndTick;
begin
  FWorkerEndTick := GetTickCount;
end;

procedure TIocpClientContext.RecordWorkerStartTick;
begin
  FWorkerStartTick := GetTickCount;
  FWorkerEndTick := 0;
end;



procedure TIocpClientContext.SetDebugInfo(const Value: string);
begin
  InnerLock;
  try
    FDebugInfo := Value;
  finally
    InnerUnLock;
  end;
end;

procedure TIocpClientContext.SetOwner(const Value: TDiocpTcpServer);
begin
  FOwner := Value;
  //FRecvRequest.FOwner := FOwner;
  {$IFDEF SOCKET_REUSE}
  {$IFDEF WRITE_LOG}
  FDisconnectExRequest.FOwner := FOwner;
  {$ENDIF}
  {$ENDIF}
end;

procedure TIocpClientContext.SetRecvWorkerHint(pvHintStr: String);
begin
//  if FRecvRequest <> nil then
//    FRecvRequest.SetWorkHintInfo(pvHintStr);
end;

procedure TIocpClientContext.SetSocketState(pvState:TSocketState);
begin
  FSocketState := pvState;
//  if Assigned(FOnSocketStateChanged) then
//  begin
//    FOnSocketStateChanged(Self);
//  end;
end;

procedure TIocpClientContext.UnLock;
begin
  FContextLocker.unLock;
end;


procedure TDiocpTcpServer.AddToOnlineList(pvObject: TIocpClientContext);
begin
  FLocker.lock('AddToOnlineList');
  try
    FOnlineContextList.Add(pvObject.FSocketHandle, pvObject);
    if DataMoniter <> nil then
    begin
      DataMoniter.CalcuMaxOnlineCount(FOnlineContextList.Count);
    end;
  finally
    FLocker.unLock;
  end;


end;

function TDiocpTcpServer.CheckClientContextValid(const pvClientContext:
    TIocpClientContext): Boolean;
begin
  Result := (pvClientContext.FOwner = Self);
end;

procedure TDiocpTcpServer.Close;
begin
  SetActive(False);
end;

constructor TDiocpTcpServer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FListeners := TDiocpListeners.Create(Self);
  FDefaultListener := TDiocpListener.Create(Self);

  FDebugStrings := TStringList.Create;
  CheckWinSocketStart;
  FUseObjectPool := true;
  FContextDNA := 0;
  FLocker := TIocpLocker.Create('diocp_tcp_server');
  FLogger:=TSafeLogger.Create();
  FLogger.setAppender(TLogFileAppender.Create(True));

  // 默认不开启心跳选项
  FKeepAlive := False;
  

  FSendRequestPool := TBaseQueue.Create;
  FRecvRequestPool := TBaseQueue.Create;
    
  FIocpEngine := TIocpEngine.Create();
  FIocpEngine.IocpCore.OnIocpException := self.OnIocpException;

  FOnlineContextList := TDHashTable.Create(10949);


  FMaxSendingQueueSize := 1000;

  // post wsaRecv block size
  FWSARecvBufferSize := 1024 * 4;

  {$IFDEF DEBUG_ON}

  {$ELSE}
  FLogger.LogFilter := [lgvError];
  {$ENDIF}
end;

destructor TDiocpTcpServer.Destroy;
begin
  FLogger.Enable := false;

  FIsDestroying := true;

  SafeStop;

  if FDataMoniter <> nil then FDataMoniter.Free;



  FSendRequestPool.FreeDataObject;
  FRecvRequestPool.FreeDataObject;

  FIocpEngine.Free;

  FOnlineContextList.Free;

  FSendRequestPool.Free;
  FRecvRequestPool.Free;

  FLogger.Free;

  FLocker.Free;
  FDebugStrings.Free;
  FListeners.Free;
  FDefaultListener.Free;
  inherited Destroy;
end;

procedure TDiocpTcpServer.AddDebugStrings(pvDebugInfo: String; pvAddTimePre:
    Boolean = true);
var
  s:string;
begin
  if pvAddTimePre then s := Format('[%s]:%s', [NowString, pvDebugInfo])
  else s := pvDebugInfo;
  FLocker.lock();
  try
    InnerAddToDebugStrings(s);
  finally
    FLocker.unLock;
  end;
end;



procedure TDiocpTcpServer.DisconnectAll;
var
  I:Integer;
  lvBucket: PDHashData;
  lvClientContext:TIocpClientContext;
begin
  FLocker.lock('DisconnectAll');
  try
    for I := 0 to FOnlineContextList.BucketSize - 1 do
    begin
      lvBucket := FOnlineContextList.Buckets[I];
      while lvBucket<>nil do
      begin
        lvClientContext := TIocpClientContext(lvBucket.Data);
        if lvClientContext <> nil then
        begin
          lvClientContext.RequestDisconnect;
        end;
        lvBucket:=lvBucket.Next;
      end;
    end;
  finally
    FLocker.unLock;
  end;
end;


function TDiocpTcpServer.LogCanWrite: Boolean;
begin
  Result := (not IsDestroying) and FLogger.Enable;
end;


procedure TDiocpTcpServer.LogMessage(pvMsg: string; const args: array of const;
    pvMsgType: string = ''; pvLevel: TLogLevel = lgvMessage);
begin
  if LogCanWrite then
  begin
    __svrLogger.logMessage(pvMsg, args, pvMsgType, pvLevel);
  end;
end;

procedure TDiocpTcpServer.LogMessage(pvMsg: string; pvMsgType: string = '';
    pvLevel: TLogLevel = lgvMessage);
begin
  if LogCanWrite then
  begin
    __svrLogger.logMessage(pvMsg, pvMsgType, pvLevel);
  end;
end;

procedure TDiocpTcpServer.DoAcceptExResponse(pvRequest: TIocpAcceptExRequest);

{$IFDEF SOCKET_REUSE}
var
  lvErrCode:Integer;
{$ELSE}
var
  lvRet:Integer;
  lvErrCode:Integer;
{$ENDIF}
  function DoAfterAcceptEx():Boolean;
  begin
    Result := true;
    if Assigned(FOnContextAccept) then
    begin
      FOnContextAccept(pvRequest.FClientContext.RawSocket.SocketHandle,
         pvRequest.FClientContext.RemoteAddr, pvRequest.FClientContext.RemotePort, Result);

      if not Result then
      begin
        {$IFDEF WRITE_LOG}
        logMessage('OnAcceptEvent vAllowAccept = false');
        {$ENDIF}
      end;
    end;
    if Result then
    begin
      if FKeepAlive then
      begin
        Result := SetKeepAlive(pvRequest.FClientContext.FRawSocket.SocketHandle, 10000);
        if not Result then
        begin
          lvErrCode := GetLastError;
          {$IFDEF DIOCP_DEBUG}
          logMessage('FClientContext.FRawSocket.setKeepAliveOption, Error:%d', [lvErrCode]);
          {$ENDIF}
        end;
      end;

      if FNoDelayOption then
      begin
        Result := pvRequest.FClientContext.FRawSocket.SetNoDelayOption(True);
        if not Result then
        begin
          lvErrCode := GetLastError;
          {$IFDEF DIOCP_DEBUG}
          logMessage('FClientContext.FRawSocket.SetNoDelayOption, Error:%d', [lvErrCode]);
          {$ENDIF}
        end;
      end;
    end;

  end;
begin
  //LogMessage('DoAcceptExResponse_Start', CORE_DEBUG_FILE);
  if pvRequest.FErrorCode = 0 then
  begin
    if DoAfterAcceptEx then
    begin
      pvRequest.FClientContext.SetSocketState(ssConnected);
     {$IFDEF SOCKET_REUSE}
      pvRequest.FClientContext.DoConnected;
     {$ELSE}
      lvRet := FIocpEngine.IocpCore.Bind2IOCPHandle(
         pvRequest.FClientContext.FRawSocket.SocketHandle, 0);
      if lvRet = 0 then
      begin     // binding error
        lvErrCode := GetLastError;

        {$IFDEF WRITE_LOG}
        logMessage(
            'bind2IOCPHandle(%d) in TDiocpTcpServer.DoAcceptExResponse occur Error :%d',
            [pvRequest.FClientContext.RawSocket.SocketHandle, lvErrCode]);
        {$ENDIF}

        DoClientContextError(pvRequest.FClientContext, lvErrCode);

        pvRequest.FClientContext.FRawSocket.Close;

        // relase client context object
        pvRequest.FClientContext.ReleaseBack;
        pvRequest.FClientContext := nil;
      end else
      begin
        pvRequest.FClientContext.DoConnected;
      end;
      {$ENDIF}
    end else
    begin
     {$IFDEF SOCKET_REUSE}
      pvRequest.FClientContext.FRawSocket.ShutDown;

      // post disconnectEx
      pvRequest.FClientContext.FDisconnectExRequest.DirectlyPost;
      pvRequest.FClientContext := nil;
     {$ELSE}
      pvRequest.FClientContext.FRawSocket.Close;

      // return to pool
      pvRequest.FClientContext.ReleaseBack;
      pvRequest.FClientContext := nil;
      {$ENDIF}
    end;
  end else
  begin
   {$IFDEF SOCKET_REUSE}
    
   {$ELSE}
    pvRequest.FClientContext.RawSocket.Close;
   {$ENDIF}
    // 归还到连接上下文池
    pvRequest.FClientContext.ReleaseBack;
    pvRequest.FClientContext := nil;
  end;

  if FActive then
  begin
    pvRequest.FAcceptorMgr.PostAcceptExRequest;
    //LogMessage('DoAcceptExResponse_END_Active', CORE_DEBUG_FILE);
  end else
  begin
    ;
    //LogMessage('DoAcceptExResponse_END_UnActive', CORE_DEBUG_FILE);
  end;
end;

procedure TDiocpTcpServer.DoClientContextError(pvClientContext:
    TIocpClientContext; pvErrorCode: Integer);
begin
  if Assigned(FOnContextError) then
    FOnContextError(pvClientContext, pvErrorCode);
end;

procedure TDiocpTcpServer.DoReceiveData(pvIocpClientContext:TIocpClientContext;
    pvRequest:TIocpRecvRequest);
begin
  if Assigned(FOnDataReceived) then
    FOnDataReceived(pvIocpClientContext,
      pvRequest.FRecvBuffer.buf, pvRequest.FBytesTransferred,
      pvRequest.FErrorCode);
end;

function TDiocpTcpServer.FindContext(pvSocketHandle:TSocket):
    TIocpClientContext;
{$IFDEF USE_HASHTABLE}

{$ELSE}
var
  lvHash:Integer;
  lvObj:TIocpClientContext;
{$ENDIF}
begin
  FLocker.lock('FindContext');
  try
    {$IFDEF USE_HASHTABLE}
    Result := TIocpClientContext(FOnlineContextList.FindFirstData(pvSocketHandle));
    {$ELSE}
    Result := nil;
    lvHash := pvSocketHandle and SOCKET_HASH_SIZE;
    lvObj := FClientsHash[lvHash];
    while lvObj <> nil do
    begin
      if lvObj.FRawSocket.SocketHandle = pvSocketHandle then
      begin
        Result := lvObj;
        break;
      end;
      lvObj := lvObj.FNextForHash;
    end;
    {$ENDIF}
  finally
    FLocker.unLock;
  end;
end;


function TDiocpTcpServer.GetWorkerCount: Integer;
begin
  Result := FIocpEngine.WorkerCount;
end;

function TDiocpTcpServer.IsDestroying: Boolean;
begin                       // 线程不安全？
  Result := FIsDestroying;  // or (csDestroying in self.ComponentState)
end;

procedure TDiocpTcpServer.OnCreateClientContext(const context:
    TIocpClientContext);
begin

end;

procedure TDiocpTcpServer.Open;
begin
  SetActive(true);
end;

procedure TDiocpTcpServer.RegisterContextClass(pvContextClass:
    TIocpClientContextClass);
begin
  FClientContextClass := pvContextClass;
end;

procedure TDiocpTcpServer.RegisterSendRequestClass(pvClass:
    TIocpSendRequestClass);
begin
  FIocpSendRequestClass := pvClass;
end;

function TDiocpTcpServer.ReleaseRecvRequest(pvObject: TIocpRecvRequest):
    Boolean;
begin
  if self = nil then
  begin
    Assert(False);
  end;
  if FRecvRequestPool = nil then
  begin
    // check call stack is crash
    Assert(FRecvRequestPool <> nil);
  end;

  if IsDebugMode then
  begin
    Assert(pvObject.FAlive)
  end;

  if UseObjectPool then
  begin
    if lock_cmp_exchange(True, False, pvObject.FAlive) = True then
    begin
      if FDataMoniter <> nil then FDataMoniter.IncRecvRequestReturnCounter;

  //    if pvObject.FBuf <> nil then
  //    begin
  //      /// Buff处理完成, 响应事件
  //      DoSendBufferCompletedEvent(pvObject.FClientContext, pvObject.FBuf, pvObject.FLen, pvObject.Tag, pvObject.ErrorCode);
  //    end;

      // 清理Buffer
     // pvObject.DoCleanUp;
      pvObject.FClientContext := nil;
    
      FRecvRequestPool.EnQueue(pvObject);
      Result := true;
    end else
    begin
      Result := false;
    end;
  end else
  begin
    pvObject.Free;
    Result := True;
  end;
end;

function TDiocpTcpServer.ReleaseSendRequest(pvObject:TIocpSendRequest): Boolean;
begin
  if self = nil then
  begin
    Assert(False);
  end;
  if FSendRequestPool = nil then
  begin
    // check call stack is crash
    Assert(FSendRequestPool <> nil);
  end;

  if IsDebugMode then
  begin
    Assert(pvObject.FAlive)
  end;

  if lock_cmp_exchange(True, False, pvObject.FAlive) = True then
  begin
    if (FDataMoniter <> nil) then
    begin
      InterlockedIncrement(FDataMoniter.FSendRequestReturnCounter);
    end;

    if pvObject.FBuf <> nil then
    begin
      /// Buff处理完成, 响应事件
      DoSendBufferCompletedEvent(pvObject.FClientContext, pvObject.FBuf, pvObject.FLen, pvObject.Tag, pvObject.ErrorCode);
    end;

    // 清理Buffer
    pvObject.DoCleanUp;
    
    FSendRequestPool.EnQueue(pvObject);
    Result := true;
  end else
  begin
    Result := false;
  end;
end;

procedure TDiocpTcpServer.RemoveFromOnOnlineList(pvObject: TIocpClientContext);
{$IFDEF USE_HASHTABLE}
  {$IFDEF DEBUG_ON}
    var
      lvSucc:Boolean;
  {$ENDIF}
{$ELSE}
var
  lvHash:Integer;
{$ENDIF}
begin
{$IFDEF USE_HASHTABLE}
  FLocker.lock('RemoveFromOnOnlineList');
  try
    {$IFDEF DEBUG_ON}
    lvSucc := FOnlineContextList.DeleteFirst(pvObject.FSocketHandle);
    Assert(lvSucc);
    {$ELSE}
    FOnlineContextList.DeleteFirst(pvObject.FSocketHandle);
    {$ENDIF}                                               
  finally
    FLocker.unLock;
  end;
{$ELSE} 
  FOnlineContextList.remove(pvObject);

  FLocker.lock('RemoveFromOnOnlineList');
  try
    // hash
    if pvObject.FPreForHash <> nil then
    begin
      pvObject.FPreForHash.FNextForHash := pvObject.FNextForHash;
      if pvObject.FNextForHash <> nil then
        pvObject.FNextForHash.FPreForHash := pvObject.FPreForHash;
    end else
    begin     // first ele
      lvHash := pvObject.RawSocket.SocketHandle and SOCKET_HASH_SIZE;
      FClientsHash[lvHash] := pvObject.FNextForHash;
      if FClientsHash[lvHash] <> nil then
        FClientsHash[lvHash].FPreForHash := nil;
    end;
  finally
    FLocker.unLock;
  end;

  pvObject.FNextForHash := nil;
  pvObject.FPreForHash := nil;
{$ENDIF}

end;

function TDiocpTcpServer.RequestContextDNA: Integer;
begin
  Result := InterlockedIncrement(FContextDNA);
end;

procedure TDiocpTcpServer.SafeStop;
begin
  if FActive then
  begin
    if FIocpEngine.WorkingCount = 0 then
    begin
      Assert(False);
    end;

    FActive := false;

    FListeners.Close;
    FDefaultListener.Close;

    DisconnectAll;

    // 等等所有的投递的AcceptEx请求回归
    // 感谢 Xjumping  990669769, 反馈bug
    FListeners.WaitForCancel(12000);
    FDefaultListener.WaitForCancel(12000);


    if not WaitForContext(120000) then
    begin  // wait time out
      Sleep(10);

      // stop workers 10's
      if not FIocpEngine.StopWorkers(10000) then
      begin        // record info
        SafeWriteFileMsg('EngineWorkerInfo:' +
           sLineBreak + FIocpEngine.GetStateINfo + sLineBreak +
           '================================================' + sLineBreak +
           'TcpServerInfo:' +
           sLineBreak + GetStateINfo, Self.Name + '_SafeStopTimeOut');
      end;

    end else
    begin    // all context is give back to pool
      if not FIocpEngine.StopWorkers(120000) then
      begin        // record info
        SafeWriteFileMsg('EngineWorkerInfo:' +
           sLineBreak + FIocpEngine.GetStateINfo + sLineBreak +
           '================================================' + sLineBreak +
           'TcpServerInfo:' +
           sLineBreak + GetStateINfo, Self.Name + '_SafeStopTimeOut');
      end;
    end;

    FListeners.ClearObjects;
    FDefaultListener.FAcceptorMgr.ClearObjects;

    FSendRequestPool.FreeDataObject;
    FSendRequestPool.Clear;

    FRecvRequestPool.FreeDataObject;
    FRecvRequestPool.Clear;

    // engine stop
    FIocpEngine.SafeStop();

    DoAfterClose;
  end; 
end;

procedure TDiocpTcpServer.SetActive(pvActive:Boolean);
begin
  if pvActive <> FActive then
  begin
    if pvActive then
    begin
      // 开启IOCP引擎
      FIocpEngine.CheckStart;

      if FDataMoniter <> nil then FDataMoniter.clear;

      if FListeners.FList.Count = 0 then
      begin
        FDefaultListener.FListenAddress := FDefaultListenAddress;
        FDefaultListener.FListenPort := FPort;
        FDefaultListener.FIPVersion := IP_V4;
        FDefaultListener.Start(FIocpEngine);
        FDefaultListener.PostAcceptExRequest(100);

      end else
      begin
        FListeners.Start(FIocpEngine);
        FListeners.PostAcceptExRequest(100);
      end;

      FActive := True;

      DoAfterOpen;
      if Assigned(FOnAfterOpen) then FOnAfterOpen(Self);
    end else
    begin
      SafeStop;
    end;
  end;
end;

procedure TDiocpTcpServer.SetMaxSendingQueueSize(pvSize:Integer);
begin
  if pvSize <= 0 then
  begin
    FMaxSendingQueueSize := 10;
  end else
  begin
    FMaxSendingQueueSize := pvSize;
  end;
end;

procedure TDiocpTcpServer.SetName(const NewName: TComponentName);
begin
  inherited;
  if FLogger.Appender is TLogFileAppender then
  begin
    if NewName <> '' then
    begin
      TLogFileAppender(FLogger.Appender).FilePreFix := NewName + '_';
    end;
  end;
end;

procedure TDiocpTcpServer.SetWorkerCount(const Value: Integer);
begin
  FIocpEngine.SetWorkerCount(Value);
end;

procedure TDiocpTcpServer.CreateDataMonitor;
begin
  if FDataMoniter = nil then
  begin
    FDataMoniter := TIocpDataMonitor.Create;
  end;
end;

procedure TDiocpTcpServer.DoAfterClose;
begin
  
end;

procedure TDiocpTcpServer.DoAfterOpen;
begin

end;

procedure TDiocpTcpServer.DoSendBufferCompletedEvent(pvContext:
    TIocpClientContext; pvBuffer: Pointer; len: Cardinal; pvBufferTag,
    pvErrorCode: Integer);
begin
  if pvContext <> nil then
  begin
    try
      pvContext.DoSendBufferCompleted(pvBuffer, len, pvBufferTag, pvErrorCode);
    except
      on e:Exception do
      begin
        LogMessage('pvContext.DoSendBufferCompleted error:' + e.Message, '', lgvError);
      end;
    end;
  end;

  if Assigned(FOnSendBufferCompleted) then
  begin
    try
      FOnSendBufferCompleted(pvContext, pvBuffer, len, pvBufferTag, pvErrorCode);
    except
      on e:Exception do
      begin
        LogMessage('DoSendBufferCompletedEvent error:' + e.Message, '', lgvError);
      end;
    end;
  end;  
end;

function TDiocpTcpServer.GetClientCount: Integer;
begin
  Result := FOnlineContextList.Count;
end;

function TDiocpTcpServer.GetContextWorkingInfo(pvTimeOut:Cardinal = 3000):
    String;
var
  lvList:TList;
  lvContext:TIocpClientContext;
  i:Integer;
  lvUseTime:Cardinal;
begin
  lvList := TList.Create;
  try
    Result := '';
    //SetCurrentThreadInfo('GetContextWorkingInfo::- 0');
    GetOnlineContextList(lvList);
    //SetCurrentThreadInfo('GetContextWorkingInfo::- 0.1');
    for i := 0 to lvList.Count - 1 do
    begin
      lvContext := TIocpClientContext(lvList[i]);
      lvUseTime := lvContext.CheckWorkingTick;
      if lvUseTime > pvTimeOut then
      begin
        Result := Result + Format('[%s:%d(t:%d)]:%s',
          [lvContext.RemoteAddr, lvContext.RemotePort, lvUseTime, lvContext.DebugInfo]) + sLineBreak;
      end;
    end;
    //SetCurrentThreadInfo('GetContextWorkingInfo::- end');
  finally
    lvList.Free;
  end;
end;

function TDiocpTcpServer.GetDebugString: String;
begin
  FLocker.lock();
  try
    Result := FDebugStrings.Text;
  finally
    FLocker.unLock;
  end;
end;

procedure TDiocpTcpServer.GetOnlineContextList(pvList:TList);
var
  I:Integer;
  lvBucket: PDHashData;
begin
  FLocker.lock('GetOnlineContextList');
  try
    for I := 0 to FOnlineContextList.BucketSize - 1 do
    begin
      lvBucket := FOnlineContextList.Buckets[I];
      while lvBucket<>nil do
      begin
        if lvBucket.Data <> nil then
        begin
           pvList.Add(lvBucket.Data);
        end;
        lvBucket:=lvBucket.Next;
      end;
    end;
  finally
    FLocker.unLock;
  end;

end;

function TDiocpTcpServer.GetPrintDebugInfo: string;
begin
  Result := Format('recv request obj:%d', [Self.FRecvRequestPool.Size]);
end;

function TDiocpTcpServer.GetRecvRequest: TIocpRecvRequest;
begin
  if UseObjectPool then
  begin
    Result := TIocpRecvRequest(FRecvRequestPool.DeQueue);
    if Result = nil then
    begin
      Result := TIocpRecvRequest.Create;
      if FDataMoniter <> nil then FDataMoniter.IncRecvRequestCreateCounter;
    end;
    Result.Tag := 0;
    Result.FAlive := true;
    //Result.DoCleanup;
    Result.FOwner := Self;
    if FDataMoniter <> nil then FDataMoniter.IncRecvRequestOutCounter;
  end else
  begin
    Result := TIocpRecvRequest.Create;
    if FDataMoniter <> nil then FDataMoniter.IncRecvRequestCreateCounter;
    Result.Tag := 0;
    Result.FAlive := true;
    Result.FOwner := Self;
    if FDataMoniter <> nil then FDataMoniter.IncRecvRequestOutCounter;
  end;
end;

function TDiocpTcpServer.GetSendRequest: TIocpSendRequest;
begin
  if Self = nil then
  begin
    if IsDebugMode then
    begin
      Assert(Self <> nil)
    end;
    Result := nil;
    Exit;
  end;
  Result := TIocpSendRequest(FSendRequestPool.DeQueue);
  if Result = nil then
  begin
    if FIocpSendRequestClass <> nil then
    begin
      Result := FIocpSendRequestClass.Create;
    end else
    begin
      Result := TIocpSendRequest.Create;
    end;
    if (FDataMoniter <> nil) then
    begin
      InterlockedIncrement(FDataMoniter.FSendRequestCreateCounter);
    end;
  end;
  Result.Tag := 0;
  Result.FAlive := true;
  //Result.DoCleanup;
  Result.FOwner := Self;
  if (FDataMoniter <> nil) then
  begin
    InterlockedIncrement(FDataMoniter.FSendRequestOutCounter);
  end;
end;

function TDiocpTcpServer.GetStateInfo: String;
var
  lvStrings:TStrings;
begin
  Result := '';
  if FDataMoniter = nil then exit;
  lvStrings := TStringList.Create;
  try
    if Active then
    begin
      lvStrings.Add(strState_Active);
    end else
    begin
      lvStrings.Add(strState_Off);
    end;


    lvStrings.Add(Format(strRecv_PostInfo,
         [
           DataMoniter.PostWSARecvCounter,
           DataMoniter.ResponseWSARecvCounter,
           DataMoniter.PostWSARecvCounter -
           DataMoniter.ResponseWSARecvCounter,
           DataMoniter.Speed_WSARecvResponse
         ]
        ));


    lvStrings.Add(Format(strRecv_SizeInfo, [TransByteSize(DataMoniter.RecvSize)]));


    //  Format('post:%d, response:%d, recvd:%d',
    //     [
    //       FIocpTcpServer.DataMoniter.PostWSARecvCounter,
    //       FIocpTcpServer.DataMoniter.ResponseWSARecvCounter,
    //       FIocpTcpServer.DataMoniter.RecvSize
    //     ]
    //    );

    lvStrings.Add(Format(strSend_Info,
       [
         DataMoniter.PostWSASendCounter,
         DataMoniter.ResponseWSASendCounter,
         DataMoniter.PostWSASendCounter -
         DataMoniter.ResponseWSASendCounter,
         DataMoniter.Speed_WSASendResponse
       ]
      ));

    lvStrings.Add(Format(strSendRequest_Info,
       [
         DataMoniter.SendRequestCreateCounter,
         DataMoniter.SendRequestOutCounter,
         DataMoniter.SendRequestReturnCounter
       ]
      ));

    lvStrings.Add(Format(strSendQueue_Info,
       [
         DataMoniter.PushSendQueueCounter,
         DataMoniter.PostSendObjectCounter,
         DataMoniter.ResponseSendObjectCounter,
         DataMoniter.SendRequestAbortCounter
       ]
      ));

    lvStrings.Add(Format(strSend_SizeInfo, [TransByteSize(DataMoniter.SentSize)]));

    lvStrings.Add(Format(strAcceptEx_Info,
       [
         DataMoniter.PostWSAAcceptExCounter,
         DataMoniter.ResponseWSAAcceptExCounter
       ]
      ));

    lvStrings.Add(Format(strSocketHandle_Info,
       [
         DataMoniter.HandleCreateCounter,
         DataMoniter.HandleDestroyCounter
       ]
      ));

    lvStrings.Add(Format(strContext_Info,
       [
         DataMoniter.ContextCreateCounter,
         DataMoniter.ContextOutCounter,
         DataMoniter.ContextReturnCounter
       ]
      ));

    lvStrings.Add(Format(strOnline_Info, [ClientCount, DataMoniter.FMaxOnlineCount]));
  
    lvStrings.Add(Format(strWorkers_Info, [WorkerCount]));

    lvStrings.Add(Format(strRunTime_Info, [GetRunTimeINfo]));

    Result := lvStrings.Text;
  finally
    lvStrings.Free;

  end;
end;

procedure TDiocpTcpServer.InnerAddToDebugStrings(pvMsg:String);
begin
  FDebugStrings.Add(pvMsg);
  if FDebugStrings.Count > 500 then FDebugStrings.Delete(0);
end;

procedure TDiocpTcpServer.KickOut(pvTimeOut:Cardinal = 60000);
var
  lvNowTickCount:Cardinal;
  I, j:Integer;
  lvContext:TIocpClientContext;
  lvKickOutList: array of TIocpClientContext;
{$IFDEF USE_HASHTABLE}
var    
  lvBucket, lvNextBucket: PDHashData;
{$ELSE}
  lvNextContext :TIocpClientContext;
{$ENDIF}
begin
  lvNowTickCount := GetTickCount;
  {$IFDEF USE_HASHTABLE}
  FLocker.lock('KickOut');
  try
    j := 0;
    if FOnlineContextList.Count > 0 then
    begin
      SetLength(lvKickOutList, FOnlineContextList.Count);
    end;
    for I := 0 to FOnlineContextList.BucketSize - 1 do
    begin
      lvBucket := FOnlineContextList.Buckets[I];
      while lvBucket<>nil do
      begin
        lvNextBucket := lvBucket.Next;
        if lvBucket.Data <> nil then
        begin
          lvContext := TIocpClientContext(lvBucket.Data);
          if lvContext.FLastActivity <> 0 then
          begin
            if (lvContext.FBusingCounter = 0)    // 如果正在(>0), 就不进行KickOut
               and (tick_diff(lvContext.FLastActivity, lvNowTickCount) > pvTimeOut) then
            begin
              // 请求关闭(异步请求关闭,不直接用RequestDisconnect()避免直接移除FOnlineContextList列表)
              lvKickOutList[j] := lvContext;
              Inc(j);
            end;
          end;
        end;
        lvBucket:= lvNextBucket;
      end;
    end;

    for i := 0 to j - 1 do
    begin
      lvKickOutList[i].RequestDisconnect('超时检测主动断开');   
    end;
  finally
    FLocker.unLock;
  end;
  {$ELSE}
  FLocker.lock('KickOut');
  try
    lvContext := FOnlineContextList.FHead;

    // request all context discounnt
    while lvContext <> nil do
    begin
      lvNextContext := lvContext.FNext;
      if lvContext.FLastActivity <> 0 then
      begin
        if tick_diff(lvContext.FLastActivity, lvNowTickCount) > pvTimeOut then
        begin
          // 请求关闭(异步请求关闭,不直接用RequestDisconnect()避免直接移除FOnlineContextList列表)
          lvContext.PostWSACloseRequest();
        end;
      end;
      lvContext := lvNextContext;
    end;
  finally
    FLocker.unLock;
  end;
  {$ENDIF}
end;

procedure TDiocpTcpServer.OnIocpException(pvRequest:TIocpRequest; E:Exception);
begin
  try
    if pvRequest <> nil then
    begin
      LogMessage('未处理异常:%s, 请求(%s)信息:%s',[E.Message, pvRequest.ClassName, pvRequest.Remark],
        CORE_LOG_FILE, lgvError);
    end else
    begin
      LogMessage('未处理异常:%s',[E.Message], CORE_LOG_FILE, lgvError);
    end;
  except
  end;
end;

procedure TDiocpTcpServer.SetWSARecvBufferSize(const Value: cardinal);
begin
  FWSARecvBufferSize := Value;
  if FWSARecvBufferSize = 0 then
  begin
    FWSARecvBufferSize := 1024 * 4;
  end;
end;

function TDiocpTcpServer.WaitForContext(pvTimeOut: Cardinal): Boolean;
var
  l:Cardinal;
  c:Integer;
begin
  l := GetTickCount;
  c := FOnlineContextList.Count;
  while (c > 0) do
  begin
    {$IFDEF MSWINDOWS}
    SwitchToThread;
    {$ELSE}
    TThread.Yield;
    {$ENDIF}

    if GetTickCount - l > pvTimeOut then
    begin
      {$IFDEF WRITE_LOG}
      logMessage('WaitForContext End Current Online num:%d', [c], CORE_LOG_FILE, lgvError);
      {$ENDIF}
      Break;
    end;
    c := FOnlineContextList.Count;
  end;

  Result := FOnlineContextList.Count = 0;
end;

procedure TIocpAcceptorMgr.PostAcceptExRequest(pvNum: Integer);
var
  i:Integer;
begin
  Assert(FOwner <> nil);

  for i := 0 to pvNum -1 do
  begin
    PostAcceptExRequest();
  end;

end;

procedure TIocpAcceptorMgr.ClearObjects;
begin
  FAcceptExRequestPool.FreeDataObject;
  FAcceptExRequestPool.Clear;

  FContextPool.FreeDataObject;
  FContextPool.Clear;
end;

constructor TIocpAcceptorMgr.Create(AOwner: TDiocpTcpServer);
begin
  inherited Create;
  FContextPool := TBaseQueue.Create;
  FCount := 0;
  FOwner := AOwner;
  FListenSocket := TRawSocket.Create;

  FAcceptExRequestPool := TBaseQueue.Create;
end;

destructor TIocpAcceptorMgr.Destroy;
begin
  FListenSocket.Free;

  FContextPool.FreeDataObject;
  FContextPool.Free;

  FAcceptExRequestPool.FreeDataObject;
  FAcceptExRequestPool.Free;

  inherited Destroy;
end;

function TIocpAcceptorMgr.GetClientContext: TIocpClientContext;
var
  lvClientClass:TIocpClientContextClass;
begin
  if not FOwner.FUseObjectPool then
  begin
    lvClientClass := FClientContextClass;
    if lvClientClass = nil then lvClientClass := FOwner.FClientContextClass;
    if lvClientClass = nil then lvClientClass := TIocpClientContext;

    Result := lvClientClass.Create;
    Result.FAcceptorMgr := Self;
    FOwner.OnCreateClientContext(Result);
    if (FOwner.FDataMoniter <> nil) then
    begin
      InterlockedIncrement(FOwner.FDataMoniter.FContextCreateCounter);
      InterlockedIncrement(FOwner.FDataMoniter.FContextOutCounter);
    end;
    Result.FSendRequestLink.SetMaxSize(FOwner.FMaxSendingQueueSize);
  end else
  begin
    Result := TIocpClientContext(FContextPool.DeQueue);
    if Result = nil then
    begin
      lvClientClass := FClientContextClass;
      if lvClientClass = nil then lvClientClass := FOwner.FClientContextClass;
      if lvClientClass = nil then lvClientClass := TIocpClientContext;

      Result := lvClientClass.Create;
      Result.FAcceptorMgr := Self;
      FOwner.OnCreateClientContext(Result);

      if (FOwner.FDataMoniter <> nil) then
      begin
        InterlockedIncrement(FOwner.FDataMoniter.FContextCreateCounter);
      end;
      Result.FSendRequestLink.SetMaxSize(FOwner.FMaxSendingQueueSize);
    end;
    if (FOwner.FDataMoniter <> nil) then
      InterlockedIncrement(FOwner.FDataMoniter.FContextOutCounter);

  end;

  Result.FAlive := True;
  Result.DoCleanUp;
  Result.Owner := FOwner;
end;

procedure TIocpAcceptorMgr.PostAcceptExRequest;
var
  lvRequest:TIocpAcceptExRequest;
  i, j:Integer;
begin
  j := 0;
  Assert(FOwner <> nil);

  try
    i := 0;
    j := 0;
    // post request

    j := 1;
    lvRequest := GetRequestObject;
    lvRequest.CheckThreadIn;
    j := 2;
    lvRequest.FClientContext := GetClientContext;
    lvRequest.FAcceptorMgr := Self;
    j := 3;

    if lvRequest.PostRequest then
    begin
      j := 4;
      if (FOwner.FDataMoniter <> nil) then
      begin
        InterlockedIncrement(FOwner.FDataMoniter.FPostWSAAcceptExCounter);
      end;
      j := 9;
    end else
    begin     // post fail
      j := 100;
      Inc(i);
      try
        // 出现异常，直接释放Context
        lvRequest.FClientContext.RawSocket.Close(False);
        lvRequest.FClientContext.FAlive := false;
        lvRequest.FClientContext.Free;
        lvRequest.FClientContext := nil;
      except
      end;
      j := 110;
      // 归还到对象池
      ReleaseRequestObject(lvRequest);
      j := 111;

      FOwner.logMessage('TIocpAcceptorMgr.PostAcceptExRequest errCounter:%d', [i], CORE_LOG_FILE);
      j := 199;
    end;
  except
    on E:Exception do
    begin
       FOwner.logMessage('TIocpAcceptorMgr.PostAcceptExRequest(%d) Err:%s', [j, e.Message], CORE_LOG_FILE);
    end;
  end;
end;

function TIocpAcceptorMgr.GetRequestObject: TIocpAcceptExRequest;
begin
  Result := TIocpAcceptExRequest(FAcceptExRequestPool.DeQueue);
  if Result = nil then
  begin
    Result := TIocpAcceptExRequest.Create(FOwner);
    if (FOwner.FDataMoniter <> nil) then
      FOwner.DataMoniter.IncAcceptExObjectCounter;
  end;
  InterlockedIncrement(FCount);
end;

procedure TIocpAcceptorMgr.RegisterContextClass(pvContextClass:
    TIocpClientContextClass);
begin
  FClientContextClass := pvContextClass;
end;

function TIocpAcceptorMgr.ReleaseClientContext(pvObject:TIocpClientContext):
    Boolean;
begin
  if not FOwner.FUseObjectPool then
  begin
    pvObject.Free;
    Result := true;
    if (FOwner.FDataMoniter <> nil) then
      InterlockedIncrement(FOwner.FDataMoniter.FContextReturnCounter);
  end else
  begin
    if lock_cmp_exchange(True, False, pvObject.FAlive) = true then
    begin
      pvObject.DoCleanUp;
      FContextPool.EnQueue(pvObject);
      if (FOwner.FDataMoniter <> nil) then
        InterlockedIncrement(FOwner.FDataMoniter.FContextReturnCounter);

      Result := true;
    end else
    begin
      Result := false;
    end;
  end;
end;

procedure TIocpAcceptorMgr.ReleaseRequestObject(pvRequest:TIocpAcceptExRequest);
begin
  pvRequest.CheckThreadOut;
  pvRequest.FAcceptorMgr := nil;
  pvRequest.FClientContext := nil;
  FAcceptExRequestPool.EnQueue(pvRequest);
  InterlockedDecrement(FCount);
end;

function TIocpAcceptorMgr.WaitForCancel(pvTimeOut: Cardinal): Boolean;
var
  l:Cardinal;
begin
  l := GetTickCount;
  while (FCount > 0) do
  begin
    {$IFDEF MSWINDOWS}
    SwitchToThread;
    {$ELSE}
    TThread.Yield;
    {$ENDIF}

    if GetTickCount - l > pvTimeOut then
    begin
      {$IFDEF WRITE_LOG}

      FOwner.logMessage('WaitForCancel End Current AccepEx num:%d', [FCount], CORE_LOG_FILE, lgvError);
      FOwner.logMessage('WaitForCancel false:' + sLineBreak +  FOwner.IocpEngine.GetStateINfo, CORE_LOG_FILE, lgvError);

      {$ENDIF}
      Break;
    end;
  end;

  Result := FCount = 0;
end;

constructor TIocpAcceptExRequest.Create(AOwner: TDiocpTcpServer);
begin
  inherited Create;
  FOwner := AOwner;
end;

procedure TIocpAcceptExRequest.GetPeerINfo;
var
  localAddr: PSockAddr;
  remoteAddr: PSockAddr;
  localAddrSize : Integer;
  remoteAddrSize : Integer;
begin
  if self.FAcceptorMgr.FListenSocket.IPVersion = IP_V6 then
  begin
    localAddrSize := SizeOf(TSockAddrIn6) + ADDRESS_LENGTH_EX;
    remoteAddrSize := SizeOf(TSockAddrIn6) + ADDRESS_LENGTH_EX;
    IocpGetAcceptExSockaddrs(@FAcceptBuffer[0],
                          0,
                          SizeOf(TSockAddrIn6) + ADDRESS_LENGTH_EX,
                          SizeOf(TSockAddrIn6) + ADDRESS_LENGTH_EX,
                          localAddr,
                          localAddrSize,
                          remoteAddr,
                          remoteAddrSize);
    //remoteAddr := PSockAddr(@FAcceptBuffer[10]);

    FClientContext.FRemoteAddr := TranslateTInAddrToString(PSockAddrIn6(remoteAddr).sin6_addr, IP_V6);
    FClientContext.FRemotePort := ntohs(PSockAddrIn6(remoteAddr).sin6_port);
  end else
  begin
    localAddrSize := SizeOf(TSockAddr) + ADDRESS_LENGTH_EX;
    remoteAddrSize := SizeOf(TSockAddr) + ADDRESS_LENGTH_EX;
    IocpGetAcceptExSockaddrs(@FAcceptBuffer[0],
                          0,
                          SizeOf(TSockAddrIn) + ADDRESS_LENGTH_EX,
                          SizeOf(TSockAddrIn) + ADDRESS_LENGTH_EX,
                          localAddr,
                          localAddrSize,
                          remoteAddr,
                          remoteAddrSize);

    FClientContext.FRemoteAddr := string(inet_ntoa(TSockAddrIn(remoteAddr^).sin_addr));
    FClientContext.FRemotePort := ntohs(TSockAddrIn(remoteAddr^).sin_port);
  end;
end;

procedure TIocpAcceptExRequest.HandleResponse;
begin
  Assert(FOwner <> nil);
  ///
  if (FOwner.FDataMoniter <> nil) then
  begin
    InterlockedIncrement(FOwner.FDataMoniter.FResponseWSAAcceptExCounter);
  end;

  if FErrorCode = 0 then
  begin
    // msdn
    // The socket sAcceptSocket does not inherit the properties of the socket
    //  associated with sListenSocket parameter until SO_UPDATE_ACCEPT_CONTEXT
    //  is set on the socket.
    FAcceptorMgr.FListenSocket.UpdateAcceptContext(FClientContext.FRawSocket.SocketHandle);

    GetPeerINfo();
  end;
  FOwner.DoAcceptExResponse(Self);
end;

function TIocpAcceptExRequest.PostRequest: Boolean;
var
  dwBytes: Cardinal;
  lvRet:BOOL;
  lvErrCode:Integer;
  lp:POverlapped;
  {$IFDEF SOCKET_REUSE}
  lvRetCode:Integer;
  {$ENDIF}
  lvListenSocket:TRawSocket;
begin
  lvListenSocket := FAcceptorMgr.ListenSocket;
  {$IFDEF SOCKET_REUSE}
  if
    (FClientContext.FRawSocket.SocketHandle = INVALID_SOCKET)
    or
    (FClientContext.FRawSocket.SocketHandle = 0) then
  begin
    if (FOwner.FDataMoniter <> nil) then
      FOwner.FDataMoniter.incHandleCreateCounter;
    FClientContext.FRawSocket.IPVersion := lvListenSocket.IPVersion;
    FClientContext.FRawSocket.CreateTcpOverlappedSocket;

    lvRetCode := FOwner.IocpEngine.IocpCore.Bind2IOCPHandle(
      FClientContext.FRawSocket.SocketHandle, 0);
    if lvRetCode = 0 then
    begin     // binding error
      lvErrCode := GetLastError;
      FOwner.logMessage(
         Format(strBindingIocpError,
           [FClientContext.FRawSocket.SocketHandle, lvErrCode, 'TIocpAcceptExRequest.PostRequest(SOCKET_REUSE)'])
         , CORE_LOG_FILE);

      FClientContext.FRawSocket.close;
      if (FOwner.FDataMoniter <> nil) then
        FOwner.FDataMoniter.incHandleDestroyCounter;
      Result := false;
      Exit;
    end;
  end;
  {$ELSE}
  FClientContext.FRawSocket.IPVersion := lvListenSocket.IPVersion;
  FClientContext.FRawSocket.CreateTcpOverlappedSocket;
  {$ENDIF}
  dwBytes := 0;
  lp := @FOverlapped;

  FClientContext.SetSocketState(ssAccepting);

  if FClientContext.RawSocket.IPVersion = IP_V6 then
  begin
    lvRet := IocpAcceptEx(lvListenSocket.SocketHandle
                  , FClientContext.FRawSocket.SocketHandle
                  , @FAcceptBuffer[0]
                  , 0
                  , SizeOf(TSockAddrIn6) + ADDRESS_LENGTH_EX
                  , SizeOf(TSockAddrIn6) + ADDRESS_LENGTH_EX
                  , dwBytes
                  , lp);
  end else
  begin
    lvRet := IocpAcceptEx(lvListenSocket.SocketHandle
                  , FClientContext.FRawSocket.SocketHandle
                  , @FAcceptBuffer[0]
                  , 0
                  , SizeOf(TSockAddrIn) + ADDRESS_LENGTH_EX
                  , SizeOf(TSockAddrIn) + ADDRESS_LENGTH_EX
                  , dwBytes
                  , lp);
  end;
  if not lvRet then
  begin
    lvErrCode := WSAGetLastError;
    Result := lvErrCode = WSA_IO_PENDING;
    if not Result then
    begin 
      FOwner.logMessage(
         Format(strBindingIocpError,
           [FClientContext.FRawSocket.SocketHandle, lvErrCode, 'TIocpAcceptExRequest.PostRequest'])
         , CORE_LOG_FILE);

      FOwner.DoClientContextError(FClientContext, lvErrCode);

      /// destroy socket
      FClientContext.RawSocket.close;
    end;
  end else
  begin
    Result := True;
  end;
end;

procedure TIocpAcceptExRequest.ResponseDone;
begin
  inherited;
  FAcceptorMgr.ReleaseRequestObject(Self);
end;

constructor TIocpRecvRequest.Create;
begin
  inherited Create;
end;

destructor TIocpRecvRequest.Destroy;
begin
  if FInnerBuffer.len > 0 then
  begin
    if __debugFlag <> 0 then
    begin
      Assert(false, 'error');
    end;
    FreeMem(FInnerBuffer.buf, FInnerBuffer.len);
  end;
  __debugFlag := GetCurrentThreadID;
  inherited Destroy;
end;

procedure TIocpRecvRequest.HandleResponse;
var
  lvDNACounter:Integer;
  lvDebugInfo:String;
  lvDebugStep:Integer;
begin
  lvDebugStep := 1;
  lvDNACounter := 0;
  try
    lvDNACounter := Self.FCounter;

    {$IFDEF DEBUG_ON}
    InterlockedDecrement(FOverlapped.RefCount);
    if FOverlapped.RefCount <> 0 then
    begin        // 引用计数异常
      if IsDebugMode then
      begin
        Assert(FOverlapped.RefCount <>0);
      end;
      {$IFDEF WRITE_LOG}
      FOwner.logMessage(strRecvResponseErr,
          [Integer(self.FClientContext), Integer(Self), FOverlapped.RefCount],
          CORE_LOG_FILE, lgvError);
      {$ENDIF}
    end;
    {$ENDIF}


    Assert(FOwner <> nil);
    try
      {$IFDEF TRACE_IOCP_RECV}
      TByteTools.AppendBufToFile(FRecvBuffer.buf,
        FBytesTransferred, Format('%s_%d_%s.recv',
        [FClientContext.RemoteAddr, FClientContext.RemotePort, FormatDateTime('hhnnsszzz', Now())]));
      {$ENDIF}

      FClientContext.FCurrRecvRequest := Self;
      lvDebugStep := 2;
      if (FOwner.FDataMoniter <> nil) then
      begin
        FOwner.FDataMoniter.incResponseWSARecvCounter;
        FOwner.FDataMoniter.incRecvdSize(FBytesTransferred);
      end;

      if not FOwner.Active then
      begin
        lvDebugStep := 10;
        {$IFDEF WRITE_LOG}
        FOwner.logMessage(
            Format(strRecvEngineOff, [FClientContext.FSocketHandle])
          );
        {$ENDIF}
        // 避免后面重复投递接收请求
        FClientContext.RequestDisconnect(
          Format(strRecvEngineOff, [FClientContext.FSocketHandle])
          , Self);
        lvDebugStep := 19;
      end else if FErrorCode <> 0 then
      begin
        lvDebugStep := 20;
        if not FClientContext.FRequestDisconnect then
        begin   // 如果请求关闭，不再输出日志,和触发错误
          {$IFDEF WRITE_LOG}
          FOwner.logMessage(
            Format(strRecvError, [FClientContext.FSocketHandle, FErrorCode])
            );
          {$ENDIF}
          FOwner.DoClientContextError(FClientContext, FErrorCode);
          FClientContext.RequestDisconnect(
            Format(strRecvError, [FClientContext.FSocketHandle, FErrorCode])
            ,  Self);
        end;
        lvDebugStep := 29;
      end else if (FBytesTransferred = 0) then
      begin      // no data recvd, socket is break
        lvDebugStep := 30;
        if not FClientContext.FRequestDisconnect then
        begin
          FClientContext.RequestDisconnect(
            Format(strRecvZero,  [FClientContext.FSocketHandle]),  Self);
        end;
        lvDebugStep := 35;
      end else
      begin
        lvDebugStep := 40;
        FClientContext.DoReceiveData(Self);
        lvDebugStep := 49;
      end;
    finally
      lvDebugInfo := FDebugInfo;

      // PostWSARecv before decReferenceCounter
      if (not FClientContext.FManulPostWSARecvRequest) and (not FClientContext.FRequestDisconnect) then
      begin                                   
        FClientContext.PostWSARecvRequest;
      end;

      // response done中 Dec
      // may return to pool
//      FClientContext.DecReferenceCounter(
//        Format('TIocpRecvRequest.WSARecvRequest.HandleResponse, DNACounter:%d, debugInfo:%s, refcount:%d',
//          [lvDNACounter, lvDebugInfo, lvRefCount]), Self);

  //  for debug context DebugStrings
  //    if FClientContext.FRequestDisconnect then
  //    begin
  //      lvBreak := true;
  //    end else
  //    begin
  //      lvBreak := False
  //    end;
  //    // may return to pool
  //    FClientContext.decReferenceCounter(
  //      Format('TIocpRecvRequest.WSARecvRequest.HandleResponse, DNACounter:%d, debugInfo:%s, refcount:%d',
  //        [lvDNACounter, FDebugInfo, FOverlapped.refCount]), Self);
  //    if lvBreak then
  //    begin
  //      FClientContext.PostWSARecvRequest;
  //    end;

    end;
  except
    on E:Exception do
    begin
      __svrLogger.logMessage(
        Format('TIocpRecvRequest.WSARecvRequest.HandleResponse, DNACounter:%d, debugInfo:%s, step:%d, refcount:%d, emsg:%s',
          [lvDNACounter, FDebugInfo, lvDebugStep, FOverlapped.refCount, e.Message]));
    end;

  end;
end;

function TIocpRecvRequest.PostRecvRequest(pvBuffer:PAnsiChar; len:Cardinal):
    Boolean;
var
  lvRet, lvDNACounter:Integer;
  lpNumberOfBytesRecvd: Cardinal;
begin
  Result := False;
  lpNumberOfBytesRecvd := 0;
  FRecvdFlag := 0;

  FRecvBuffer.buf := pvBuffer;
  FRecvBuffer.len := len;
  lvDNACounter := InterlockedIncrement(FCounter);
  if FClientContext.IncReferenceCounter(Format(
    'TIocpRecvRequest.WSARecvRequest.Post, DNACounter:%d', [lvDNACounter]), Self) then
  begin
    {$IFDEF DEBUG_ON}
    if FOverlapped.RefCount <> 0 then
    begin
      Assert(FOverlapped.RefCount = 0);
    end;
    InterlockedIncrement(FOverlapped.refCount);
    {$ENDIF}
    FDebugInfo := IntToStr(intPtr(FClientContext));
    lvRet := diocp_winapi_winsock2.WSARecv(FClientContext.FRawSocket.SocketHandle,
       @FRecvBuffer,
       1,
       lpNumberOfBytesRecvd,
       FRecvdFlag,
       LPWSAOVERLAPPED(@FOverlapped),   // d7 need to cast
       nil
       );
    if lvRet = SOCKET_ERROR then
    begin
      lvRet := WSAGetLastError;
      Result := lvRet = WSA_IO_PENDING;
      if not Result then
      begin
        {$IFDEF WRITE_LOG}
        FOwner.logMessage(strRecvPostError, [FClientContext.SocketHandle, lvRet]);
        {$ENDIF}
        {$IFDEF DEBUG_ON}
        InterlockedDecrement(FOverlapped.refCount);
        {$ENDIF}

        // trigger error event
        FOwner.DoClientContextError(FClientContext, lvRet);

        // decReferenceCounter
        FClientContext.DecReferenceCounterAndRequestDisconnect(
        'TIocpRecvRequest.WSARecvRequest.Error', Self);

      end else
      begin
        if (FOwner <> nil) and (FOwner.FDataMoniter <> nil) then
        begin
          FOwner.FDataMoniter.incPostWSARecvCounter;
        end;
      end;
    end else
    begin
      Result := True;
    
      if (FOwner <> nil) and (FOwner.FDataMoniter <> nil) then
      begin
        FOwner.FDataMoniter.incPostWSARecvCounter;
      end;
    end;   
  end;
end;

procedure TIocpRecvRequest.ResponseDone;
var
  lvContext:TIocpClientContext;
begin
  inherited;
  if FOwner = nil then
  begin
    if IsDebugMode then
    begin
      Assert(FOwner <> nil);
      Assert(Self.FAlive);
    end;
  end else
  begin
    // fclientcontext is nil
    lvContext := FClientContext;
    try
      FOwner.ReleaseRecvRequest(Self);
    finally
      lvContext.DecReferenceCounter('TIocpRecvRequest.WSARecvRequest.Response Done', Self);
    end;
  end;  
end;

function TIocpRecvRequest.PostRecvRequest: Boolean;
begin
  if FInnerBuffer.len <> FOwner.FWSARecvBufferSize then
  begin
    if FInnerBuffer.len > 0 then FreeMem(FInnerBuffer.buf);
    FInnerBuffer.len := FOwner.FWSARecvBufferSize;
    GetMem(FInnerBuffer.buf, FInnerBuffer.len);
  end;
  Result := PostRecvRequest(FInnerBuffer.buf, FInnerBuffer.len);
end;

procedure TIocpRecvRequest.ReleaseBack;
begin
  FOwner.ReleaseRecvRequest(Self);
end;

function TIocpSendRequest.ExecuteSend: Integer;
begin
  if Tag = -1 then
  begin
    FLastMsg := strWSACloseRequest;
    Result := -2;
  end else if (FBuf = nil) or (FLen = 0) then
  begin
    FLastMsg := strWSACloseRequest;
    Result := -2;
  end else
  begin
    if InnerPostRequest(FBuf, FLen) then
    begin
      Result := 0;
    end else
    begin
      Result := -1;
    end;
  end;

end;

procedure TIocpSendRequest.CheckClearSendBuffer;
begin
  if FLen > 0 then
  begin
    case FSendBufferReleaseType of
      dtDispose: Dispose(FBuf);
      dtFreeMem: FreeMem(FBuf);
    end;
  end;
  FSendBufferReleaseType := dtNone;
  FLen := 0;
end;

constructor TIocpSendRequest.Create;
begin
  inherited Create;
end;

destructor TIocpSendRequest.Destroy;
begin
  CheckClearSendBuffer;
  inherited Destroy;
end;

procedure TIocpSendRequest.DoCleanUp;
begin
  CheckClearSendBuffer;
  FBytesSize := 0;
  FNext := nil;
  FOwner := nil;
  FClientContext := nil;
  FReponseState := 0;


  //FMaxSize := 0;
end;

procedure TIocpSendRequest.HandleResponse;
var
  lvContext:TIocpClientContext;
begin
  lvContext := FClientContext;
  FIsBusying := false;
  try
    Assert(FOwner<> nil);
    if (FOwner.FDataMoniter <> nil) then
    begin                                                       
      FOwner.FDataMoniter.incSentSize(FBytesTransferred);
      FOwner.FDataMoniter.incResponseWSASendCounter;
    end;   

    // 响应完成事件
    lvContext.DoSendRequestRespnonse(Self);

    if not FOwner.Active then
    begin
      FReponseState := 4;
      {$IFDEF WRITE_LOG}
      FOwner.logMessage(
          Format(strSendEngineOff, [FClientContext.FSocketHandle])
          );
      {$ENDIF}
      // avoid postWSARecv
      FClientContext.RequestDisconnect(
        Format(strSendEngineOff, [FClientContext.FSocketHandle])
        , Self);
    end else if FErrorCode <> 0 then
    begin
      FReponseState := 3;

      if not FClientContext.FRequestDisconnect then
      begin   // 如果请求关闭，不再输出日志,和触发错误
        {$IFDEF WRITE_LOG}
        FOwner.logMessage(
            Format(strSendErr, [FClientContext.FSocketHandle, FErrorCode])
            );
        {$ENDIF}
        FOwner.DoClientContextError(FClientContext, FErrorCode);
        FClientContext.RequestDisconnect(
           Format(strSendErr, [FClientContext.FSocketHandle, FErrorCode])
            , Self);
      end;
    end else if FBytesTransferred <> FBytesSize then
    begin
      FClientContext.RequestDisconnect(
        Format(strSendSizeErr, [FClientContext.FSocketHandle, FBytesSize, FBytesTransferred])
        , Self);
    end else
    begin
      FReponseState := 2;
      if FOwner.FDataMoniter <> nil then
      begin
        FOwner.FDataMoniter.incResponseSendObjectCounter;
      end;

      if Assigned(FOnDataRequestCompleted) then
      begin
        FOnDataRequestCompleted(FClientContext, Self);
      end;

      FClientContext.DoSendRequestCompleted(Self);

      FClientContext.PostNextSendRequest;
    end;
  finally
//    if FClientContext = nil then
//    begin
//      Assert(False);
//      FReponseState := lvResponseState;
//    end;
    // response done中 Dec

  end;
end;

function TIocpSendRequest.InnerPostRequest(buf: Pointer; len: Cardinal):
    Boolean;
var
  lvErrorCode, lvRet: Integer;
  dwFlag: Cardinal;
  lpNumberOfBytesSent:Cardinal;
  lvContext:TIocpClientContext;
  lvOwner:TDiocpTcpServer;
begin
  Result := false;
  FIsBusying := True;
  FBytesSize := len;
  FWSABuf.buf := buf;
  FWSABuf.len := len;
  dwFlag := 0;
  lvErrorCode := 0;
  lpNumberOfBytesSent := 0;

  // maybe on HandleResonse and release self
  lvOwner := FOwner;



  lvContext := FClientContext;
  if lvContext.incReferenceCounter('InnerPostRequest::WSASend_Start', self) then
  try
    {$IFDEF TRACE_IOCP_SEND}
    TByteTools.AppendBufToFile(buf, len, Format('%s_%d_%s.send', [lvContext.RemoteAddr, lvContext.RemotePort, FormatDateTime('hhnnsszzz', Now())]));
    {$ENDIF}

    lvRet := WSASend(lvContext.FRawSocket.SocketHandle,
                      @FWSABuf,
                      1,
                      lpNumberOfBytesSent,
                      dwFlag,
                      LPWSAOVERLAPPED(@FOverlapped),   // d7 need to cast
                      nil
    );
    if lvRet = SOCKET_ERROR then
    begin
      lvErrorCode := WSAGetLastError;
      Result := lvErrorCode = WSA_IO_PENDING;
      if not Result then
      begin
       FIsBusying := False;
       {$IFDEF WRITE_LOG}
       lvOwner.logMessage(
         Format(strSendPostError, [lvContext.FSocketHandle, lvErrorCode])
         );
       {$ENDIF}
        /// request kick out
       lvContext.RequestDisconnect(
          Format(strSendPostError, [lvContext.FSocketHandle, lvErrorCode])
          , Self);
      end else
      begin      // maybe on HandleResonse and release self
        if (lvOwner <> nil) and (lvOwner.FDataMoniter <> nil) then
        begin
          lvOwner.FDataMoniter.incPostWSASendSize(len);
          lvOwner.FDataMoniter.incPostWSASendCounter;
        end;
      end;
    end else
    begin       // maybe on HandleResonse and release self
      Result := True;
      if (lvOwner <> nil) and (lvOwner.FDataMoniter <> nil) then
      begin
        lvOwner.FDataMoniter.incPostWSASendSize(len);
        lvOwner.FDataMoniter.incPostWSASendCounter;
      end;
    end;
  finally
    if not Result then
    begin      // post fail, dec ref, if post succ, response dec ref
      if IsDebugMode then
      begin
        Assert(lvContext = FClientContext);
      end;
      lvContext.decReferenceCounter(
        Format('InnerPostRequest::WSASend_Fail, ErrorCode:%d', [lvErrorCode])
         , Self);

    end;

    // if result is true, maybe on HandleResponse dispose and push back to pool

  end;
end;

procedure TIocpSendRequest.ResponseDone;
var
  lvContext:TIocpClientContext;
begin
  inherited;
  if FOwner = nil then
  begin
    if IsDebugMode then
    begin
      Assert(FOwner <> nil);
      Assert(Self.FAlive);
    end;
  end else
  begin
    lvContext := FClientContext;
    try
      FOwner.ReleaseSendRequest(Self);
    finally
      lvContext.DecReferenceCounter('TIocpSendRequest.WSASendRequest.Response Done', Self);
    end;
  end;
end;

procedure TIocpSendRequest.SetBuffer(buf: Pointer; len: Cardinal;
  pvBufReleaseType: TDataReleaseType);
begin
  CheckClearSendBuffer;
  FBuf := buf;
  FLen := len;
  FSendBufferReleaseType := pvBufReleaseType;
end;

procedure TIocpSendRequest.SetBuffer(buf: Pointer; len: Cardinal; pvCopyBuf: Boolean = true);
var
  lvBuf: PAnsiChar;
begin
  if pvCopyBuf then
  begin
    GetMem(lvBuf, len);
    Move(buf^, lvBuf^, len);
    SetBuffer(lvBuf, len, dtFreeMem);
  end else
  begin
    SetBuffer(buf, len, dtNone);
  end;

//
//  if pvCopyBuf then
//  begin
//    if FCopyBuf.len > 0 then FreeMem(FCopyBuf.buf);
//
//    FCopyBuf.len := len;
//    GetMem(FCopyBuf.buf, FCopyBuf.len);
//    Move(buf^, FCopyBuf.buf^, FCopyBuf.len);
//    FBuf := FCopyBuf.buf;
//    FLen := FCopyBuf.len;
//  end else
//  begin
//    FBuf := buf;
//    FLen := len;
//  end;
//  FPosition := 0;
end;

procedure TIocpSendRequest.UnBindingSendBuffer;
begin
  FBuf := nil;
  FLen := 0;
  FSendBufferReleaseType := dtNone;
end;

function TIocpSendRequest.GetStateINfo: String;
begin
  Result :=Format('%s %s', [Self.ClassName, self.Remark]);
  if FResponding then
  begin
    Result :=Result + sLineBreak + Format('start:%s, datalen:%d, max:%d',
      [FormatDateTime('MM-dd hh:nn:ss.zzz', FRespondStartTime), FWSABuf.len, FMaxSize]);
  end else
  begin
    Result :=Result + sLineBreak + Format('start:%s, end:%s, datalen:%d, max:%d',
      [FormatDateTime('MM-dd hh:nn:ss.zzz', FRespondStartTime),
        FormatDateTime('MM-dd hh:nn:ss.zzz', FRespondEndTime),
        FWSABuf.len, FMaxSize]);
  end;
end;

function TIocpSendRequest.GetWSABuf: PWsaBuf;
begin
  Result := @FWSABuf;
end;

procedure TIocpDataMonitor.CalcuMaxOnlineCount(pvOnlineCount: Integer);
begin
  if pvOnlineCount > FMaxOnlineCount then FMaxOnlineCount := pvOnlineCount;
end;

procedure TIocpDataMonitor.Clear;
begin
  FLocker.Enter;
  try
    FSentSize:=0;
    FRecvSize:=0;
    FPostWSASendSize:=0;

    FContextCreateCounter := 0;
    FPostWSASendCounter:=0;
    FResponseWSASendCounter:=0;

    FSendRequestCreateCounter := 0;
    FSendRequestOutCounter := 0;
    FSendRequestReturnCounter := 0;
    FSendRequestAbortCounter := 0;
    FPostSendObjectCounter := 0;


    
    FPostWSARecvCounter:=0;
    FResponseWSARecvCounter:=0;

    FRecvRequestCreateCounter:=0;
    FRecvRequestReturnCounter:=0;
    FRecvRequestOutCounter:=0;
    

    FPushSendQueueCounter := 0;
    FResponseSendObjectCounter := 0;

    FSpeed_WSASentSize := 0;
    FSpeed_WSARecvSize := 0;
    FLastSpeed_RecvSize := 0;
    FLastSpeed_WSASentSize := 0;



    //FPostWSAAcceptExCounter:=0;
    //FResponseWSAAcceptExCounter:=0;
  finally
    FLocker.Leave;
  end;
end;

constructor TIocpDataMonitor.Create;
begin
  inherited Create;
  FLocker := TCriticalSection.Create();
end;



destructor TIocpDataMonitor.Destroy;
begin
  FLocker.Free;
  inherited Destroy;
end;

procedure TIocpDataMonitor.IncAcceptExObjectCounter;
begin
   InterlockedIncrement(FAcceptExObjectCounter); 
end;

procedure TIocpDataMonitor.incPushSendQueueCounter;
begin
  InterlockedIncrement(FPushSendQueueCounter);
end;

{$IFDEF SOCKET_REUSE}
procedure TIocpDataMonitor.incHandleCreateCounter;
begin
  InterlockedIncrement(FHandleCreateCounter);
end;

procedure TIocpDataMonitor.incHandleDestroyCounter;
begin
  InterlockedIncrement(FHandleDestroyCounter);
end;
{$ENDIF}

procedure TIocpDataMonitor.incPostSendObjectCounter;
begin
  InterlockedIncrement(FPostSendObjectCounter);
end;


procedure TIocpDataMonitor.IncPostWSARecvCounter;
begin
  InterlockedIncrement(FPostWSARecvCounter);
end;

procedure TIocpDataMonitor.incPostWSASendCounter;
begin
  InterlockedIncrement(FPostWSASendCounter);
end;

procedure TIocpDataMonitor.incPostWSASendSize(pvSize: Cardinal);
begin
  FLocker.Enter;
  try
    FPostWSASendSize := FPostWSASendSize + pvSize;
  finally
    FLocker.Leave;
  end;
end;

procedure TIocpDataMonitor.incRecvdSize(pvSize: Cardinal);
begin
  FLocker.Enter;
  try
    FRecvSize := FRecvSize + pvSize;
  finally
    FLocker.Leave;
  end;
end;

procedure TIocpDataMonitor.IncRecvRequestCreateCounter;
begin
  InterlockedIncrement(FRecvRequestCreateCounter);
end;

procedure TIocpDataMonitor.IncRecvRequestOutCounter;
begin
  InterlockedIncrement(FRecvRequestOutCounter);
end;

procedure TIocpDataMonitor.IncRecvRequestReturnCounter;
begin
  InterlockedIncrement(FRecvRequestReturnCounter);
end;

procedure TIocpDataMonitor.incResponseSendObjectCounter;
begin
  InterlockedIncrement(FResponseSendObjectCounter);
end;

procedure TIocpDataMonitor.IncResponseWSARecvCounter;
begin
  InterlockedIncrement(FResponseWSARecvCounter);
end;

procedure TIocpDataMonitor.IncResponseWSASendCounter;
begin
  InterlockedIncrement(FResponseWSASendCounter);
end;

procedure TIocpDataMonitor.IncSentSize(pvSize:Cardinal);
begin
  FLocker.Enter;
  try
    FSentSize := FSentSize + pvSize;
  finally
    FLocker.Leave;
  end;
end;

procedure TIocpDataMonitor.SpeedCalcuEnd;
var
  lvTick:Cardinal;
  lvSec:Double;
begin
  if FLastSpeedTick = 0 then exit;

  lvTick := tick_diff(FLastSpeedTick, GetTickCount);
  if lvTick = 0 then Exit;

  lvSec := (lvTick / 1000.000);
  if lvSec = 0 then Exit;

  FSpeed_WSASendResponse := Trunc((FResponseWSASendCounter - FLastSpeed_WSASendResponse) / lvSec);


  FSpeed_WSARecvResponse := Trunc((self.FResponseWSARecvCounter - FLastSpeed_WSARecvResponse) / lvSec);

end;

procedure TIocpDataMonitor.SpeedCalcuStart;
begin
  FLastSpeedTick := GetTickCount;
  FLastSpeed_WSASendResponse := FResponseWSASendCounter;
  FLastSpeed_WSARecvResponse := FResponseWSARecvCounter;
end;

{ TIocpDisconnectExRequest }


function TIocpDisconnectExRequest.DirectlyPost: Boolean;
var
  lvErrorCode:Integer;
begin
  Result := IocpDisconnectEx(FContext.RawSocket.SocketHandle, @FOverlapped, TF_REUSE_SOCKET, 0);
  if not Result then
  begin
    lvErrorCode := WSAGetLastError;
    if lvErrorCode <> ERROR_IO_PENDING then
    begin
      // do normal close;
      FContext.RawSocket.close;
      {$IFDEF WRITE_LOG}
      FOwner.logMessage('TIocpDisconnectExRequest.PostRequest Error:%d',  [lvErrorCode]);
      {$ENDIF}

      // context may return to pool
      FContext.decReferenceCounter(
        Format('TIocpDisconnectExRequest.PostRequest Error: %d', [lvErrorCode]), Self
        );
      Result := false;
    end else
    begin
      Result := true;
    end;
  end;
end;

function TIocpDisconnectExRequest.PostRequest: Boolean;
var
  lvErrorCode:Integer;
begin
  Result := False;

  if FContext.incReferenceCounter('TIocpDisconnectExRequest.PostRequest', Self) then
  begin
    Result := IocpDisconnectEx(FContext.RawSocket.SocketHandle, @FOverlapped, TF_REUSE_SOCKET, 0);
    if not Result then
    begin
      lvErrorCode := WSAGetLastError;
      if lvErrorCode <> ERROR_IO_PENDING then
      begin
        // do normal close;
        FContext.RawSocket.close;
        {$IFDEF WRITE_LOG}
        FOwner.logMessage('TIocpDisconnectExRequest.PostRequest Error:%d',  [lvErrorCode]);
        {$ENDIF}

        // context may return to pool
        FContext.decReferenceCounter(
          Format('TIocpDisconnectExRequest.PostRequest Error: %d', [lvErrorCode]), Self
          );
        Result := false;
      end else
      begin
        Result := true;
      end;
    end;
  end;
end;

procedure TDiocpListeners.Close;
var
  i: Integer;
begin
  for i := 0 to FList.Count -1 do
  begin
    TDiocpListener(FList[i]).FAcceptorMgr.FListenSocket.Close(False);
  end;
end;

constructor TDiocpListeners.Create(AOwnerTcpServer: TDiocpTcpServer);
begin
  inherited Create;
  FOwnerServer := AOwnerTcpServer;
  FList := TList.Create();
end;

destructor TDiocpListeners.Destroy;
begin
  Clear;
  FreeAndNil(FList);
  inherited Destroy;
end;

procedure TDiocpListeners.Bind(const pvBindingAddress: string; const pvPort:
    Integer; pvIPVersion: Integer = IP_V4; pvClientContextClass:
    TIocpClientContextClass = nil);
var
  lvItem:TDiocpListener;
  i: Integer;
begin
  for i := 0 to FList.Count - 1 do
  begin
    lvItem := TDiocpListener(FList[i]);
    if
      (SameText(lvItem.FListenAddress, pvBindingAddress))
      and
      (lvItem.FListenPort = pvPort)
      and
      (lvItem.FIPVersion = pvIPVersion)
    then
    begin
      raise Exception.Create(Format('请不要重复绑定(%s:%d)', [pvBindingAddress,pvPort]));
    end;
  end;

  lvItem := TDiocpListener.Create(FOwnerServer);
  lvItem.FListenAddress := pvBindingAddress;
  lvItem.FListenPort := pvPort;
  lvItem.FIPVersion := pvIPVersion;
  lvItem.FAcceptorMgr.FClientContextClass := pvClientContextClass;
  FList.Add(lvItem);
end;

procedure TDiocpListeners.Clear;
var
  i: Integer;
begin
  for i := 0 to FList.Count -1 do
  begin
    TDiocpListener(FList[i]).Free;
  end;
  FList.Clear;

end;

procedure TDiocpListeners.ClearObjects;
var
  i: Integer;
begin
  for i := 0 to FList.Count -1 do
  begin
    TDiocpListener(FList[i]).FAcceptorMgr.ClearObjects;
  end;

end;

procedure TDiocpListeners.PostAcceptExRequest(pvNum: Integer);
var
  i: Integer;
begin
  for i := 0 to FList.Count -1 do
  begin
    TDiocpListener(FList[i]).PostAcceptExRequest(pvNum);
  end;
end;

procedure TDiocpListeners.Start(pvIocpEngine: TIocpEngine);
var
  i: Integer;
begin
  for i := 0 to FList.Count -1 do
  begin
    TDiocpListener(FList[i]).Start(pvIocpEngine);
  end;
end;

procedure TDiocpListeners.WaitForCancel(pvTimeOut:Integer);
var
  i: Integer;
begin
  for i := 0 to FList.Count -1 do
  begin
    TDiocpListener(FList[i]).FAcceptorMgr.WaitForCancel(pvTimeOut)
  end;
end;

procedure TDiocpListener.Close;
begin
  FAcceptorMgr.FListenSocket.Close(False);
end;

constructor TDiocpListener.Create(AOwnerTcpServer: TDiocpTcpServer);
begin
  inherited Create;
  FAcceptorMgr := TIocpAcceptorMgr.Create(AOwnerTcpServer);
end;

destructor TDiocpListener.Destroy;
begin
  FreeAndNil(FAcceptorMgr);
  inherited Destroy;
end;


procedure TDiocpListener.PostAcceptExRequest(pvNum: Integer);
begin
  FAcceptorMgr.PostAcceptExRequest(100);
end;

procedure TDiocpListener.Start(pvIocpEngine: TIocpEngine);
var
  lvListenSocket:TRawSocket;
begin
  try
    lvListenSocket := FAcceptorMgr.FListenSocket;
    lvListenSocket.IPVersion  := FIPVersion;
    lvListenSocket.CreateTcpOverlappedSocket;

    // 绑定侦听端口
    if not lvListenSocket.Bind(FListenAddress, FListenPort) then
    begin
      try
        RaiseLastOSError;
      finally
        lvListenSocket.Close(False);
      end;
    end;

    // 开启侦听
    if not lvListenSocket.listen() then
    begin
      try
        RaiseLastOSError;
      finally
        lvListenSocket.Close(False);
      end;
    end;

    // 将侦听套接字绑定到IOCP句柄
    if pvIocpEngine.IocpCore.Bind2IOCPHandle(lvListenSocket.SocketHandle, 0) <= 0 then
    begin
      try
        RaiseLastOSError;
      finally
        lvListenSocket.Close(False);
      end;
    end;
  except
    on E:Exception do
    begin
       Raise Exception.Create(Format(strListenFail, [FListenAddress, FListenPort, e.Message]));
    end;
  end;
end;

procedure TDiocpListener.WaitForCancel(pvTimeOut: Integer);
begin
  FAcceptorMgr.WaitForCancel(pvTimeOut);
end;

initialization
  __startTime :=  Now();
  __innerLogger := TSafeLogger.Create();
  __innerLogger.setAppender(TLogFileAppender.Create(True));

  {$IFDEF DIOCP_HIGH_SPEED}
  __innerLogger.LogFilter := [lgvError, lgvWarning, lgvWriteFile];
  {$ENDIF}

  __svrLogger := __innerLogger;

finalization
  if __innerLogger <> nil then
  begin
    __innerLogger.Free;
  end;



end.
