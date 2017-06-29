{
#########################################################
# Copyright by Alexander Benikowski                     #
# This unit is part of the Delphinus project hosted on  #
# https://github.com/Memnarch/Delphinus                 #
#########################################################
}
unit DN.Setup.Intf;

interface

uses
  DN.Types,
  DN.Package.Intf,
  DN.Package.Version.Intf,
  DN.Progress.Intf;

type
  IDNSetup = interface
    ['{F853423C-9D61-49DA-824B-F6AEE55D3F7B}']
    function GetComponentDirectory: string;
    procedure SetComponentDirectory(const Value: string);
    function GetOnMessage: TMessageEvent;
    procedure SetOnMessage(const Value: TMessageEvent);
    function GetOnProgress: TDNProgressEvent;
    procedure SetOnProgress(const Value: TDNProgressEvent);
    function GetHasPendingChanges: Boolean;
    function Install(const APackage: IDNPackage; const AVersion: IDNPackageVersion): Boolean;
    function Update(const APackage: IDNPackage; const AVersion: IDNPackageVersion): Boolean;
    function Uninstall(const APackage: IDNPackage): Boolean;
    function InstallDirectory(const APackage: IDNPackage; const ADirectory: string): Boolean;
    function UninstallDirectory(const ADirectory: string): Boolean;
    property ComponentDirectory: string read GetComponentDirectory write SetComponentDirectory;
    property OnMessage: TMessageEvent read GetOnMessage write SetOnMessage;
    property OnProgress: TDNProgressEvent read GetOnProgress write SetOnProgress;
    property HasPendingChanges: Boolean read GetHasPendingChanges;
  end;

implementation

end.
