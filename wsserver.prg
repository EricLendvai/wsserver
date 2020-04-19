#include "inkey.ch"
#include "hbsocket.ch"

#define ADDRESS    "127.0.0.1"
#define PORT       9000
#define TIMEOUT    3000    // 3 seconds
#define CRLF       Chr( 13 ) + Chr( 10 )
#define FILEHEADER "data:application/octet-stream;base64,"
#define JSONHEADER "data:application/json;base64,"

//----------------------------------------------------------------//

function Main()

   local hListen, hSocket

   if ! hb_mtvm()
      ? "multithread support required"
      return
   endif

   if Empty( hListen := hb_socketOpen( HB_SOCKET_AF_INET, HB_SOCKET_PT_STREAM, HB_SOCKET_IPPROTO_TCP ) )
      ? "socket create error " + hb_ntos( hb_socketGetError() )
   endif

   if ! hb_socketBind( hListen, { HB_SOCKET_AF_INET, ADDRESS, PORT } )
      ? "bind error " + hb_ntos( hb_socketGetError() )
   endif

   if ! hb_socketListen( hListen )
      ? "listen error " + hb_ntos( hb_socketGetError() )
   endif

   ? "Harbour websockets server running on port " + hb_ntos( PORT )

   while .T.
      if Empty( hSocket := hb_socketAccept( hListen,, TIMEOUT ) )
         if hb_socketGetError() == HB_SOCKET_ERR_TIMEOUT
            // ? "loop"
         ELSE
            ? "accept error " + hb_ntos( hb_socketGetError() )
         endif
      ELSE
         ? "accept socket request"
         hb_threadDetach( hb_threadStart( @ServeClient(), hSocket ) )
      endif
      if Inkey() == K_ESC
         ? "quitting - esc pressed"
         EXIT
      endif
   end

   ? "close listening socket"

   hb_socketShutdown( hListen )
   hb_socketClose( hListen )

return nil

//----------------------------------------------------------------//

function HandShaking( hSocket, cHeaders )   

   local aHeaders := hb_ATokens( cHeaders, CRLF )
   local hHeaders := {=>}, cLine 
   local cAnswer

   for each cLine in aHeaders
      hHeaders[ SubStr( cLine, 1, At( ":", cLine ) - 1 ) ] = SubStr( cLine, At( ":", cLine ) + 2 )
   next

   cAnswer = "HTTP/1.1 101 Web Socket Protocol Handshake" + CRLF + ;
             "Upgrade: websocket" + CRLF + ;
             "Connection: Upgrade" + CRLF + ;
             "WebSocket-Origin: " + ADDRESS + CRLF + ;
             "WebSocket-Location: ws://" + ADDRESS + ":" + hb_ntos( PORT ) + CRLF + ;
             "Sec-WebSocket-Accept: " + ;
             hb_Base64Encode( hb_SHA1( hHeaders[ "Sec-WebSocket-Key" ] + ;
                              "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", .T. ) ) + CRLF + CRLF

   hb_socketSend( hSocket, cAnswer ) 

return nil   

//----------------------------------------------------------------//

function Unmask( cText )
   
   local nLen := hb_bitAnd( hb_bPeek( cText, 2 ), 127 ) 
   local cMask, cData, cChar

   do case
      case nLen = 126
         cMask = SubStr( cText, 5, 4 )
         cData = SubStr( cText, 9 )

      case nLen = 127   
         cMask = SubStr( cText, 11, 4 )
         cData = SubStr( cText, 15 )
         
      otherwise
         cMask = SubStr( cText, 3, 4 )
         cData = SubStr( cText, 7 )
   endcase 

   cText = ""
   for each cChar in cData
      cText += Chr( hb_bitXor( Asc( cChar ),;
                    hb_bPeek( cMask, ( ( cChar:__enumIndex() - 1 ) % 4 ) + 1 ) ) ) 
   next   

return cText 

//----------------------------------------------------------------//

function NetworkULL2Bin( n )

   local nBytesLeft := 64
   local cBytes := ""

   while nBytesLeft > 0
      nBytesLeft -= 8
      cBytes += Chr( hb_BitShift( hb_BitShift( n, -nBytesLeft ), 0xFF ) )
   end

return cBytes

//----------------------------------------------------------------//

function Mask( cText, lEnd )

   local nLen := Len( cText ) 
   local cHeader 
   local lMsgIsComplete := .T., lMsgIsText := .T.
   local nFirstByte := 0
                  
   hb_default( @lEnd, .F. )

   if lMsgIsComplete
      nFirstByte = hb_bitSet( nFirstByte, 7 ) // 1000 0000
   endif

   if lMsgIsText 
      nFirstByte = hb_bitSet( nFirstByte, 0 ) // 1000 0001
   endif

   if lEnd
      nFirstByte = hb_bitSet( nFirstByte, 3 ) // 1000 1001
   endif   

   do case
      case nLen <= 125
         cHeader = Chr( nFirstByte ) + Chr( nLen )   

      case nLen < 65536
         cHeader = Chr( nFirstByte ) + Chr( 126 ) + ;
                   Chr( hb_BitShift( nLen, -8 ) ) + Chr( hb_BitAnd( nLen, 0xFF ) )
         
      otherwise 
         cHeader = Chr( nFirstByte ) + Chr( 127 ) + NetworkULL2Bin( nLen )   
   endcase

return cHeader + cText   

//----------------------------------------------------------------//

function ServeClient( hSocket )

   local cRequest
   local nLen
   local cBuf := Space( 4096 )

   hb_socketRecv( hSocket, @cBuf,,, 1024 )
   HandShaking( hSocket, AllTrim( cBuf ) )

   ? "new client connected"

   while .T.
      cBuf = Space( 10000 )
      cRequest = ""

      if ( nLen := hb_socketRecv( hSocket, @cBuf,,, TIMEOUT ) ) > 0  
         cRequest = Left( cBuf, nLen )
         cRequest = UnMask( cRequest )
         
         if Left( cRequest, Len( FILEHEADER ) ) == FILEHEADER
            cRequest = hb_base64Decode( SubStr( cRequest, Len( FILEHEADER ) + 1 ) )
         endif
         
         if Left( cRequest, Len( JSONHEADER ) ) == JSONHEADER
            cRequest = hb_base64Decode( SubStr( cRequest, Len( JSONHEADER ) + 1 ) )
         endif
         
         do case
            case cRequest == "exit"
                 hb_socketSend( hSocket, Mask( "exiting", .T. ) )  // Close handShake
                 
            case cRequest == "exiting" // client answered to Close handShake
                 exit
                 
            otherwise     
                  ? cRequest
                  hb_socketSend( hSocket, Mask( cRequest ) )
         endcase

         // else
         //    if nLen == -1
         //       ? "recv() error:", hb_socketGetError() 
         //    endif
      endif 
   end

   ? "close socket"

   hb_socketShutdown( hSocket )
   hb_socketClose( hSocket )

return nil

//----------------------------------------------------------------//
