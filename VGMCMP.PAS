PROGRAM VGMCMP;
{ By FreddyV, December 2021 V0.1 }

{$UNDEF DEBUG}

Uses crt,dos;

CONST

 BuffSize = 1024*16;
 CMSRegNb = $1F;
 MinDelay = 735; { Minimal Delay betwen 2 Device Output }

TYPE

     Bytes6=Array[1..6] of Byte;
	 String12=String[12];


 T_VGMHeader=Record
          ID : Array[1..4] of Char;
	      Size : Longint;
          VerL : Byte; { Version Low BCD  }
          VerH : Byte; { Version High BCD }
	      VerD : Word;
	      SN76489Clk : Longint;   { Tandy Chip }
	      YM2413Clk  : LongInt;
	      DG3TagOffset : Longint; { Information Tag Offset }
	      TotSamples : Longint;
	      LoopOffset : Longint;
	      LoopSamp   : Longint;
	      { v1.01 }
	      Rate : Longint;
	      { v1.10 }
	      SNFeedback : Longint;
	      YM2612Clk  : Longint;
	      YM2151Clk  : Longint;
	      { v1.50 }
	      DataOffset : Longint;
          f1 : Array[1..6] of  Longint;
		  YM3812Clk : Longint; { OPL2 v1.51 }
		  f2 : Longint;
		  f3 : Longint;
		  YMF262Clk  : Longint; { OPL3 v1.51 }
		  YMF278BClk : Longint;
		  YMF271Clk  : Longint;
		  YMZ280BClk : Longint;
		  RC52C164Clk: Longint;
		  f4: Array[1..22] of Longint;
		  SAA1099Clk: Longint;
	     End;

VAR

   i,j     : Integer;

   SearchStr: String;
   DirStr   : String;
   DirStr_Size: Integer;
   
   VGMFileName: String;
   FileNameNoExt: String;
   VGMFileNameOut: String;
   
   VGMFile : File;
   VGMFileOut : File;
   VGMSize    : Longint;
   VGMOutSize : Longint;
   VGMDG3Size : Integer;

   Info : SearchRec;
   Count : Longint;

   
   VGMHeader : T_VGMHeader;
   VGMHeader2 : Array[1..128] of Longint; { Header buffer for the final Read/Write }
   
   VGMDataOffset : Longint; { Offset of the Data in the file }
   VGMDataEnd : Longint;    { Index of the Data End in file  }
   VGMStreamSize : Longint; { Size of the Stream Data        }
 
   BufferIn   : Array[1..BuffSize] of Byte;
   BufferOut  : Array[1..BuffSize] of Byte;

   ByteRead:Word;
   ByteWritten:Word;

{ Variables used to perform the compression }

   FileIndex : LongInt;   {Last Byte of the current loaded stream Block }
   Out_Size  : LongInt;
   Index_In  : Word;      { Current index in the Input Stream Buffer }
   Index_Out : Word;      { Current index in the Output Stream Buffer }
   StreamBlockSize:Word;  { Size of the current loaded Block   }
   StreamEnd:Boolean;     { Set to one when it is the end of the Stream }
   CurDelay: LongInt;     { Curent Delay }

   CMDIsDelay: Boolean; { Set to true if the command is a Delay }

{ CMS Registry copy }
  RegNb : Byte;
  RegVal: Byte;
  CMSRegChanged : Boolean;
  CMSReg     : Array[0..CMSRegNb] of Byte;
  CMSRegInit : Array [0..CMSRegNb] of Boolean;
  CMSChanged : Array [0..CMSRegNb] of Boolean;

  CMS2Reg     : Array[0..CMSRegNb] of Byte;
  CMS2RegInit : Array [0..CMSRegNb] of Boolean;
  CMS2Changed : Array [0..CMSRegNb] of Boolean;

{
; 0x50  dd  PSG (SN76489/SN76496) write value dd  
; 0x5E  aa dd  YMF262 port 0, write value dd to register aa
; 0x5F  aa dd  YMF262 port 1, write value dd to register aa  
; 0x5A  aa dd  YM3812, write value dd to register aa
; 0x61  nn nn  Wait n samples, n can range from 0 to 65535 (approx 1.49 seconds).
;              Longer pauses than this are represented by multiple wait commands.
; 0x62   wait 735 samples (60th of a second), a shortcut for 0x61 0xdf 0x02  
; 0x63   wait 882 samples (50th of a second), a shortcut for 0x61 0x72 0x03
; 0x7n   wait n+1 samples, n can range from 0 to 15.
  0xBD  aa dd SAA1099, write value dd to register aa
}

{ Read a block of the Stream Data to the BufferIn table }
 Procedure ReadStreamBloc; 
 Begin
 
 If (VGMStreamSize-FileIndex)<BuffSize then
     StreamBlockSize:=VGMStreamSize-FileIndex
    Else StreamBlockSize:=BuffSize;

  If StreamBlockSize<>0 then 
   Begin
    FileIndex:=FileIndex+StreamBlockSize;
    BlockRead(VGMFile,BufferIn,StreamBlockSize,ByteRead);
	Index_In:=1;
   End;

 End;
 
 Function ReadStreamByte:Byte;
  Begin
  If (Index_In>StreamBlockSize) then { If End of the Block, read next part }
    Begin
     ReadStreamBloc;                            { Read next Block   }
     If StreamBlockSize=0 then StreamEnd:=True; { End of the Stream }
    End;
  ReadStreamByte:=BufferIn[Index_In];
  Index_In:=Index_In+1
 End;

 Procedure WriteStreamBloc;
  Begin { Save Data Block to the output }
  { Ecrite IndexOut-1 Octets}
  If Index_Out>1 then
   Begin
    BlockWrite(VGMFileOut,BufferOut,Index_Out-1,ByteWritten);
    Out_Size:=Out_Size+Index_Out-1;
    Index_Out:=1;
   End;
  End;

 Procedure WriteStreamByte(B:Byte);
  Begin
  If (Index_Out>BuffSize) then { If End of the Block, read next part }
     WriteStreamBloc;          { Read next Bloc   }
  BufferOut[Index_Out]:=B;
  Index_Out:=Index_Out+1
  End;

PROCEDURE OptimizeVGMStream;

VAR

 StrCMD  : Byte;
 StrDataB : Byte;
 StrDataW : Word;

 Begin
 StreamEnd:=False;
 FileIndex:=0;
 CurDelay:=0;
 Index_In:=1;
 Index_Out:=1;
 Out_Size:=0;
 
 ReadStreamBloc; { Read the first Stream Block }

 for i:=0 to CMSRegNb do
  Begin
   CMSRegInit[i]:=False;
   CMSChanged[i]:=False;
   CMS2RegInit[i]:=False;
   CMS2Changed[i]:=False; 
  end;

CMSRegChanged:=False;

Repeat 
 
  StrCMD:=ReadStreamByte;
  CMDIsDelay:=False;
  {Write('/C:',StrCMD,' ');}
 {Write('/');}
  
  If not StreamEnd then
   Begin
    Case StrCMD of
      $4F: Begin
	        WriteStreamByte(StrCMD);
            StrDataB:=ReadStreamByte;
            WriteStreamByte(StrDataB);
           End;
      $50: Begin  { SN76489 / Tandy }
	        WriteStreamByte(StrCMD);
            StrDataB:=ReadStreamByte;
            WriteStreamByte(StrDataB);
 {           Write ('50h: SN76489 ',StrDataB);}
           End;
      $51..$59: Begin
	             WriteStreamByte(StrCMD);
                 StrDataB:=ReadStreamByte;
	             WriteStreamByte(StrDataB);
                 StrDataB:=ReadStreamByte;
                 WriteStreamByte(StrDataB);
                End;
	  $5A: Begin  {YM3812 / OPL2}
            WriteStreamByte(StrCMD); 
            StrDataB:=ReadStreamByte;
            WriteStreamByte(StrDataB);
{            Write ('5Eh: YMF262 port 0 ',StrDataB);}
            StrDataB:=ReadStreamByte;
            WriteStreamByte(StrDataB);
{			 Write (',',StrDataB);}
           End;
	  $5B..$5D: Begin
	             WriteStreamByte(StrCMD);
	             StrDataB:=ReadStreamByte;
                     WriteStreamByte(StrDataB);
                     StrDataB:=ReadStreamByte;
                     WriteStreamByte(StrDataB);
                    End;
	  $5E: Begin  {YMF262 port 0 / OPL3}
	         WriteStreamByte(StrCMD);
	         StrDataB:=ReadStreamByte;
			 WriteStreamByte(StrDataB);
{            Write ('5Eh: YMF262 port 0 ',StrDataB);}
	         StrDataB:=ReadStreamByte;
			 WriteStreamByte(StrDataB);
{			 Write (',',StrDataB);}
           End;
      $5F: Begin  {YMF262 port 1 / OPL3}
            WriteStreamByte(StrCMD);
            StrDataB:=ReadStreamByte;
            WriteStreamByte(StrDataB);
{            Write ('5Eh: YMF262 port 0 ',StrDataB);}
            StrDataB:=ReadStreamByte;
            WriteStreamByte(StrDataB);
{			 Write (',',StrDataB);}
           End;
      $BD: Begin  {SAA1099 / CMS}

            { CMS Command are not sent directly to the Output Stream
             We simulate the reg write and flush all changes later }
			RegNb := ReadStreamByte;
            RegVal:= ReadStreamByte;
			If (RegNb AND $80)=0 then 
			   Begin 
			   RegNb:=(RegNb AND $1F);
			   If Not CMSRegInit[RegNb] then 
			      Begin
				   CMSRegInit[RegNb]:=True;
				   CMSChanged[RegNb]:=True;
				   CMSReg[RegNb]:=RegVal;
				   CMSRegChanged:=True
				  End
                   Else
                  Begin
                   If CMSReg[RegNb]<>RegVal then
				      Begin 
                       CMSChanged[RegNb]:=True;
				       CMSReg[RegNb]:=RegVal;
					   CMSRegChanged:=True
					  End;
                  End;					             				   
			   End
			   Else   
			   Begin 
			   RegNb:=(RegNb AND $1F);
			   If Not CMS2RegInit[RegNb] then 
			      Begin 
				   CMS2RegInit[RegNb]:=True;
				   CMS2Changed[RegNb]:=True;
				   CMS2Reg[RegNb]:=RegVal;
				   CMSRegChanged:=True
				  End
                   Else
                  Begin
                   If CMS2Reg[RegNb]<>RegVal then
				      Begin 
                       CMS2Changed[RegNb]:=True;
				       CMS2Reg[RegNb]:=RegVal;
					   CMSRegChanged:=True
					  End;
                  End;
			   End;
           End;

{ Delay Commands }
	  $61: Begin
                StrDataB:=ReadStreamByte;
                StrDataW:=ReadStreamByte*256+StrDataB;
               { Write('Wait ',StrDataW);}

                CurDelay:=CurDelay+StrDataW;
                CMDIsDelay:=True;
	       End;
	  $62: Begin
	       { Write('Wait 1/60 s');}
                CurDelay:=CurDelay+735;
                CMDIsDelay:=True;
	       End;
	  $63: Begin
            {    Write('Wait 1/50 s');}
                CurDelay:=CurDelay+883;
                CMDIsDelay:=True;
	       End;
      $66: Begin
                WriteStreamByte(StrCMD);		  
                StreamEnd:=True; { Stop }
               End;
       $70..$7F:
	       Begin
                StrDataB:=(StrCMD AND $0F)+1;
                CurDelay:=CurDelay+StrDataB;
              {  Write('7xh: Wait ',StrDataB);}
                CMDIsDelay:=True;
              End;

     End; { Case StrCMD }

       If (CurDelay>=MinDelay) then
          Begin

		{   Writeln('Delay:',CurDelay,' IndexIn:',Index_In ,' IndexOut: ',Index_Out); }
           If CMSRegChanged then 
		      Begin { Something changed in the CMS Registers > Save before the Delay }

               {Write all the Changed registers values (Chip 1)} 
               For i:=0 to CMSRegNb do
                    If CMSChanged[i] then 
					   Begin
					    WriteStreamByte($BD);
						WriteStreamByte(i);
						WriteStreamByte(CMSReg[i]);
					   End;

               {Write all the Changed registers values (Chip 2)}
               For i:=0 to CMSRegNb do
                    If CMS2Changed[i] then
					   Begin
					    WriteStreamByte($BD);
						WriteStreamByte(i+$80);
						WriteStreamByte(CMS2Reg[i]);
					   End;						

               For i:=0 to CMSRegNb do { Reset the Registers changed Flag }
                   Begin
                    CMSChanged[i]:=False;
                    CMS2Changed[i]:=False; 
					{CMSRegInit[i]:=False;
					CMS2RegInit[i]:=False;}
                   end;

			  End;
           If (CurDelay=735) then
               Begin
	            StrDataB:=$62;
		        WriteStreamByte(StrDataB);
		      End
                Else If (CurDelay=833) then
	         Begin
                  StrDataB:=$63;
                  WriteStreamByte(StrDataB);
		  End
	        Else
                 Begin
                  StrDataB:=$61;
                  WriteStreamByte(StrDataB);
	          StrDataB:=CurDelay AND $FF;
                  WriteStreamByte(StrDataB);
                  StrDataB:=CurDelay SHR 8;
                  WriteStreamByte(StrDataB);
                 End;
          CurDelay:=0;

         End;




   End; { Not StreamEnd }

Until StreamEnd;

{FileIndex:=FileIndex+StreamBlockSize;} { Update FileIndex }
WriteStreamBloc; { Write the Last Data Block }

End;

Procedure Opt_VGM;

Var IOErr:Byte;

Begin

{ Read the input file }
{$I-}
Assign(VGMFile,VGMFileName);
{$I+}
IOErr:=IOResult;
If IOErr<>0 then
   Begin
    Writeln('File open Error: ',IOErr);
    EXIT
   End;
{$I-}
Rename(VGMFile,FileNameNoExt+'.OLD');        {!!!!}
{$I+}
IOErr:=IOResult;
If IOErr<>0 then
   Begin
    Writeln('File Rename Error: ',IOErr);
	Writeln(FileNameNoExt+'.OLD Still exist, File Conversion Skipped.');
	Close(VGMFile);
    EXIT
   End;
reset(VGMFile,1); { Open file for Read }

VGMSize:=FileSize(VGMFile);
BlockRead(VGMFile,VGMHeader,Sizeof(VGMHeader),ByteRead);

If VGMHeader.ID<>'Vgm ' then
   Begin
     Writeln('VGM File ID Not found');
    { Liberer memoire }
     EXIT;
   End;

If (VGMHeader.VerH>=1) and (VGMHeader.VerL>=$50) then
   Begin
    VGMDataOffset:=VGMHeader.DataOffset+$34;
   End
    Else VGMDataOffset:=$40;

If VGMHeader.DG3TagOffset<>0 then
   Begin
    VGMDataEnd:=VGMHeader.DG3TagOffset+20;
    If VGMDataEnd>VGMSize then Writeln('WARNING: DG3Tag Offset > File Size !');
   End
    Else VGMDataEnd:=VGMSize;

VGMStreamSize:=VGMDataEnd-VGMDataOffset;

{$IFDEF DEBUG}
Writeln('* Input file Infos:');
Writeln('VGM Version: ',VGMHeader.VerH,' ',VGMHeader.VerL);
Writeln('File Size  :',VGMSize, ' - Header.Size :',VGMHeader.Size);
If VGMHeader.DG3TagOffset=0 then Writeln('No DG3 Tag')
   Else Writeln('DG3 Offset :',VGMHeader.DG3TagOffset);
Writeln('Data Offset :',VGMDataOffset);
Writeln('Data End    : ',VGMDataEnd);
Writeln('StreamSize : ',VGMStreamSize);

{ V 1.0 Support only the SN76489 }
If (VGMHeader.VerH>=1) and (VGMHeader.VerL>=$51) then
    Begin
          {Writeln(' Version >= 1.51 ');}
    If VGMHeader.SN76489Clk<>0 then Writeln('SN76489 (Tandy)');
    If VGMHeader.YM3812Clk<>0 then Writeln('OPL2');
    If VGMHeader.YMF262Clk<>0 then Writeln('OPL3');
    If (VGMHeader.SAA1099Clk<>0) and (VGMHeader.VerL>=$71) then	Writeln('SAA1099 (CMS)')
    End;
{$ENDIF}

{ Open the Output file }
{$I-}
Assign(VGMFileOut,VGMFileName);
rewrite(VGMFileOut,1);  { Open the file for Write }
{$I+}
IOErr:=IOResult;
If IOErr<>0 then
   Begin
    Writeln('Output File Creation Error (',VGMFileName, '): ',IOErr);
	Close(VGMFile);
    EXIT
   End;

Seek(VGMFile,VGMDataOffset);
Seek(VGMFileOut,VGMDataOffset); { Re Create another file, with the same Header }

OptimizeVGMStream;

{ ** Copy the Header }
{$IFDEF DEBUG}
Writeln('* After Compression');
Writeln('FileIndex: ',FileIndex);
Writeln('Out_Size: ',Out_Size);

Writeln('Out_Size+VGMDataOffset: ',Out_Size+VGMDataOffset);
Writeln('VGMSize:',VGMSize);
Writeln('VGMHeader.DG3TagOffset:',VGMHeader.DG3TagOffset);
Writeln('VGMSize-VGMHeader.DG3TagOffset:',VGMSize-VGMHeader.DG3TagOffset);
{$ENDIF}

Seek(VGMFile,0);
BlockRead(VGMFile,VGMHeader2,VGMDataOffset,ByteRead); { Read the Complete Header }

If VGMHeader.DG3TagOffset<>0 then 
   Else VGMDG3Size:=0;

{ Out_Size is the Size of the Output file Stream Data }
If VGMHeader.DG3TagOffset<>0 then
   Begin
   VGMHeader2[6]:=(Out_Size+VGMDataOffset-20); { Modify the DG3 Tag Offset }
   VGMDG3Size:=VGMSize-(VGMHeader.DG3TagOffset+20);
   End;
{ Header Size + Stream Size + DG3Tag Size -4 }
VGMHeader2[2]:=Out_Size+VGMDataOffset+VGMDG3Size-4;   { Final File Size -4 }


Seek(VGMFileOut,0);
BlockWrite(VGMFileOut,VGMHeader2,VGMDataOffset,ByteWritten);

{ ** Copy the DG3Tag}
If VGMHeader.DG3TagOffset<>0 then 
   Begin
   If (VGMDG3Size>0) and (VGMDG3Size<16*1024) then
    Begin
     Seek(VGMFile,(VGMHeader.DG3TagOffset+20));
	 BlockRead(VGMFile,BufferIn,VGMDG3Size,ByteRead); { Read the DG3 Tag }

	 Seek(VGMFileOut,Out_Size+VGMDataOffset);                { Move to the end of the Out file }
	 BlockWrite(VGMFileOut,BufferIn,VGMDG3Size,ByteWritten); { Write the DG3Tag }
	End;
   End;


VGMOutSize:=Out_Size+VGMDataOffset+VGMDG3Size;
Writeln('File Size Before: ',VGMSize,' After : ',Out_Size+VGMDataOffset+VGMDG3Size);
Close(VGMFile);
Close(VGMFileOut);

End;

Begin

Writeln('VGM Compress Utility v0.1 by FreddyV');
Writeln('December 2021');

If ParamCount=0 then
  Begin
  Writeln('Command Line: VGMCMP FileName');
  Writeln('You can use * in the file name to convert multiple files');
  Writeln('CVMCMP will Optimize the VGM File by removing the not needed delays');
  Writeln('The Original file will be renamed as Filename.OLD');
  Writeln('Optimized for CMS (Remove not needed CMS Command), should work with OPL2/Tandy');
  EXIT;
  End;
 
If ParamCount>1 then
  Begin
  Writeln('Please provide the input file name in the command line');
  Writeln('Error: More than one parameter detected');
  EXIT;
  End;
 
SearchStr:=ParamStr(1);

{ Build the Directory String }
 i:=Length(SearchStr);
 DirStr_Size:=0;
 DirStr:='';
 Repeat
  If (SearchStr[i] in ['\',':']) Then DirStr_Size:=i;
  Dec(i)
 Until (i=0) or (DirStr_Size>0);
 If DirStr_Size>0 Then DirStr:=Copy(SearchStr,1,DirStr_Size); 

{ Replace the extention by VGM }
 i:=Length(SearchStr);
 j:=0;
 Repeat
  If (SearchStr[i]='.') Then j:=i-1;
  Dec(i)
 Until (i=0) or (j>0);
 If j>0 Then
     SearchStr:=Copy(SearchStr,1,j); {Remove any extention}
 SearchStr:=SearchStr+'.VGM';

{ Search all the files and start the Optimization }

{ Writeln('Directory: ',DirStr);
 Writeln('Search ',SearchStr);}
  
  Count:=0;
  FindFirst (SearchStr,AnyFile,Info);
   While DOSError=0 do
    Begin
      Inc(Count);
      With Info do
        begin
{        If (Attr and Directory) = Directory then
          Write('Dir : ');
        Writeln (Name:12,Size:8);}
		
		VGMFilename:=DirStr+Name;
		FileNameNoExt:=Copy(VGMFilename,1,Length(VGMFilename)-4);
		Writeln('File Name : ',VGMFilename);
		{ Do the File Optimization }
		Opt_VGM;
		
        end;
     FindNext(Info);
    End;

End.