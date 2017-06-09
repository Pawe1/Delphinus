unit DN.PackageProvider.Bitbucket;

interface

uses
  Classes,
  Types,
  Graphics,
  SysUtils,
  SyncObjs,
  Generics.Collections,
  DN.Package.Bitbucket,
  DN.Package.Intf,
  DN.PackageProvider,
  DN.JSonFile.CacheInfo,
  DN.Progress.Intf,
  DN.HttpClient.Intf,
  DN.JSon,
  DN.JSOnFile.Info,
  DN.PackageProvider.State.Intf,
  DN.Package.Version.Intf;

type
  TDNBitbucketPackageProvider = class(TDNPackageProvider, IDNProgress, IDNPackageProviderState)
  private
    FProgress: IDNProgress;
    FPushDates: TDictionary<string, string>;
    FExistingIDs: TDictionary<TGUID, Integer>;
    FDateMutex: TMutex;
    FState: IDNPackageProviderState;
    FLoadPictures: Boolean;
    function LoadVersionInfo(const APackage: IDNPackage; const AAuthor, AName, AFirstVersion, AReleases: string): Boolean;
    procedure AddDependencies(const AVersion: IDNPackageVersion; AInf: TInfoFile);
    procedure AddPackageFromJSon(AJSon: TJSONObject);
    function CreatePackageWithMetaInfo(AItem: TJSONObject; out APackage: IDNPackage): Boolean;
    procedure LoadPicture(APicture: TPicture; AAuthor, ARepository, AVersion, APictureFile: string);
    function GetInfoFile(const AAuthor, ARepository, AVersion: string; AInfo: TInfoFile): Boolean;
    function GetFileText(const AAuthor, ARepository, AVersion, AFilePath: string; out AText: string): Boolean;
    function GetFileStream(const AAuthor, ARepository, AVersion, AFilePath: string; AFile: TStream): Boolean;
    function GetReleaseText(const AAuthor, ARepository: string; out AReleases: string): Boolean;
    procedure HandleDownloadProgress(AProgress, AMax: Int64);
    procedure CheckRateLimit;
  protected
    FClient: IDNHttpClient;
    function GetLicense(const APackage: TDNBitbucketPackage): string;
    function GetPushDateFile: string;
    function GetRepoList(out ARepos: TJSONArray): Boolean; virtual;
    procedure SavePushDates;
    procedure LoadPushDates;
    //properties for interfaceredirection
    property Progress: IDNProgress read FProgress implements IDNProgress;
    property State: IDNPackageProviderState read FState implements IDNPackageProviderState;
  public
    constructor Create(const AClient: IDNHttpClient; ALoadPictures: Boolean = True);
    destructor Destroy(); override;
    function Reload(): Boolean; override;
    function Download(const APackage: IDNPackage; const AVersion: string; const AFolder: string; out AContentFolder: string): Boolean; override;
  end;

const
  CBitbucketOAuthAuthentication = 'token %s';

implementation

uses
  IOUtils,
  DateUtils,
  DN.IOUtils,
  StrUtils,
  jpeg,
  pngimage,
  DN.Version,
  DN.Types,
  DN.Package,
  DN.Zip,
  DN.Package.Version,
  DN.Package.Dependency,
  DN.Package.Dependency.Intf,
  DN.Progress,
  DN.Environment,
  DN.Graphics.Loader,
  DN.PackageProvider.Bitbucket.State;

const
  CBitbucketFileContent = 'https://api.bitbucket.org/2.0/repositories/%s/%s/downloads  /contents/%s?ref=%s';//user/repo filepath/branch
  CGitRepoSearch = 'https://api.bitbucket.org/2.0 api.github.com/search/repositories?q="Delphinus-Support"+in:readme&per_page=100';
  CBitbucketRepoReleases = 'https://api.bitbucket.org/2.0 api.github.com/repos/%s/%s/releases';// user/repo/releases
  CMediaTypeRaw = 'application/vnd.github.v3.raw';
  CPushDates = 'PushDates.ini';

type
  ERateLimitException = EAbort;

{ TDCPMPackageProvider }

procedure TDNBitbucketPackageProvider.AddDependencies(
  const AVersion: IDNPackageVersion; AInf: TInfoFile);
var
  LInfDependency: TInfoDependency;
  LDependency: IDNPackageDependency;
begin
  for LInfDependency in AInf.Dependencies do
  begin
    LDependency := TDNPackageDependency.Create(LInfDependency.ID, LInfDependency.Version);
    AVersion.Dependencies.Add(LDependency);
  end;
end;

procedure TDNBitbucketPackageProvider.AddPackageFromJSon(AJSon: TJSONObject);
var
  LPackage: IDNPackage;
begin
  if CreatePackageWithMetaInfo(AJSon, LPackage) then
  begin
    Packages.Add(LPackage);
  end;
end;

procedure TDNBitbucketPackageProvider.CheckRateLimit;
var
  LUnixTime: Int64;
  LResetTime: TDateTime;
begin
  if FClient.ResponseHeader['X-RateLimit-Remaining'] = '0' then
  begin
    LUnixTime := StrToInt64Def(FClient.ResponseHeader['X-RateLimit-Reset'], 0);
    LResetTime := TTimeZone.Local.ToLocalTime(UnixToDateTime(LUnixTime));
    raise ERateLimitException.Create('Ratelimit exceeded. Wait for reset. Reset is at ' + DateTimeToStr(LResetTime));
  end;
end;

constructor TDNBitbucketPackageProvider.Create;
var
  LKey: string;
begin
  inherited Create();
  FClient := AClient;
  FProgress := TDNProgress.Create();
  FPushDates := TDictionary<string, string>.Create();
  FExistingIDs := TDictionary<TGUID, Integer>.Create();
  LKey := StringReplace(GetPushDateFile(), '\', '/', [rfReplaceAll]);
  FDateMutex := TMutex.Create(nil, False, LKey);
//  FState := TDNBitbucketPackageProviderState.Create(FClient);
  FLoadPictures := ALoadPictures;
end;

function TDNBitbucketPackageProvider.CreatePackageWithMetaInfo(AItem: TJSONObject;
  out APackage: IDNPackage): Boolean;
var
  LPackage: TDNBitbucketPackage;
  LName, LAuthor, LDefaultBranch, LReleases: string;
  LFullName, LPushDate, LOldPushDate: string;
  LHeadInfo: TInfoFile;
  LHomePage: TJSONValue;
  LHeadVersion: TDNPackageVersion;
const
  CArchivePlaceholder = '{archive_format}{/ref}';
begin
  Result := False;
  LFullName := AItem.GetValue('full_name').Value;
  LPushDate := AItem.GetValue('pushed_at').Value;
  if not FPushDates.TryGetValue(LFullName, LOldPushDate) then
    LOldPushDate := '';

  LName := AItem.GetValue('name').Value;
  LAuthor := TJSonObject(AItem.GetValue('owner')).GetValue('login').Value;
  LDefaultBranch := AItem.GetValue('default_branch').Value;
  if not GetReleaseText(LAuthor, LName, LReleases) then
    Exit(False);

  //if nothing was pushed or released since last refresh, we can go fullcache and not contact the server
  FClient.IgnoreCacheExpiration := (LPushDate = LOldPushDate) and (FClient.LastResponseSource = rsCache);
  LHeadInfo := TInfoFile.Create();
  try
    if GetInfoFile(LAuthor, LName, LDefaultBranch, LHeadInfo) and not FExistingIDs.ContainsKey(LHeadInfo.ID) then
    begin
      FExistingIDs.Add({LHeadInfo.ID} tguid.NewGuid, 0);
      LPackage := TDNBitbucketPackage.Create();
      LPackage.OnGetLicense := GetLicense;
      LPackage.Description := AItem.GetValue('description').Value;
      LPackage.DownloadLoaction := AItem.GetValue('archive_url').Value;
      LPackage.DownloadLoaction := StringReplace(LPackage.DownloadLoaction, CArchivePlaceholder, 'zipball/', []);
      LPackage.Author := LAuthor;
      LPackage.RepositoryName := LName;
      LPackage.DefaultBranch := LDefaultBranch;

      LPackage.ProjectUrl := AItem.GetValue('html_url').Value;
      LHomePage := AItem.GetValue('homepage');
      if LHomePage is TJSONString then
        LPackage.HomepageUrl := LHomePage.Value;

      if AItem.GetValue('has_issues') is TJSONTrue then
        LPackage.ReportUrl := LPackage.ProjectUrl + '/issues';

      if LHeadInfo.Name <> '' then
        LPackage.Name := LHeadInfo.Name
      else
        LPackage.Name := LName;
      LPackage.ID := LHeadInfo.ID;
      LPackage.CompilerMin := LHeadInfo.PackageCompilerMin;
      LPackage.CompilerMax := LHeadInfo.PackageCompilerMax;
      LPackage.LicenseType := LHeadInfo.LicenseType;
      LPackage.LicenseFile := LHeadInfo.LicenseFile;
      LPackage.Platforms := LHeadInfo.Platforms;
      APackage := LPackage;
      if FLoadPictures then
        LoadPicture(APackage.Picture, LAuthor, LPackage.RepositoryName, LPackage.DefaultBranch, LHeadInfo.Picture);
      LoadVersionInfo(APackage, LAuthor, LName, LHeadInfo.FirstVersion, LReleases);
      LHeadVersion := TDNPackageVersion.Create();
      LHeadVersion.Name := 'HEAD';
      LHeadVersion.Value := TDNVersion.Create();
      LHeadVersion.CompilerMin := LHeadInfo.CompilerMin;
      LHeadVersion.CompilerMax := LHeadInfo.CompilerMax;
      AddDependencies(LHeadVersion, LHeadInfo);
      APackage.Versions.Add(LHeadVersion);
      FPushDates.AddOrSetValue(LFullName, LPushDate);
      Result := True;
    end;
  finally
    LHeadInfo.Free;
    FClient.IgnoreCacheExpiration := False;
  end;
end;

destructor TDNBitbucketPackageProvider.Destroy;
begin
  FDateMutex.Free();
  FPushDates.Free();
  FExistingIDs.Free();
  FClient := nil;
  FProgress := nil;
  inherited;
end;

function TDNBitbucketPackageProvider.Download(const APackage: IDNPackage;
  const AVersion: string; const AFolder: string; out AContentFolder: string): Boolean;
var
  LArchiveFile, LFolder: string;
  LDirs: TStringDynArray;
const
  CNamePrefix = 'filename=';
begin
  FProgress.SetTasks(['Downloading']);
  LArchiveFile := TPath.Combine(AFolder, 'Package.zip');
  FClient.OnProgress := HandleDownloadProgress;
  Result := FClient.Download(APackage.DownloadLoaction + IfThen(AVersion <> '', AVersion, (APackage as TDNBitbucketPackage).DefaultBranch), LArchiveFile) = HTTPErrorOk;
  FClient.OnProgress := nil;
  if Result then
  begin
    LFolder := TPath.Combine(AFolder, TGuid.NewGuid.ToString);
    Result := ForceDirectories(LFolder);
    if Result then
      Result := ShellUnzip(LArchiveFile, LFolder);
  end;

  if Result then
  begin
    LDirs := TDirectory.GetDirectories(LFolder);
    Result := Length(LDirs) = 1;
    if Result then
      AContentFolder := LDirs[0];
  end;
  TFile.Delete(LArchiveFile);
end;

function TDNBitbucketPackageProvider.LoadVersionInfo(
  const APackage: IDNPackage; const AAuthor, AName,
  AFirstVersion, AReleases: string): Boolean;
var
  LArray: TJSONArray;
  LObject: TJSonObject;
  i: Integer;
  LVersionName: string;
  LInfo: TInfoFile;
  LVersion: IDNPackageVersion;
begin
  Result := False;
  LInfo := TInfoFile.Create();
  try
    LArray := TJSOnObject.ParseJSONValue(AReleases) as TJSONArray;
    try
      for i := 0 to LArray.Count - 1 do
      begin
        LObject := LArray.Items[i] as TJSonObject;
        LVersionName := LObject.GetValue('tag_name').Value;
        if GetInfoFile(AAuthor, AName, LVersionName, LInfo) then
        begin
          LVersion := TDNPackageVersion.Create();
          LVersion.Name := LVersionName;
          LVersion.CompilerMin := LInfo.CompilerMin;
          LVersion.CompilerMax := LInfo.CompilerMax;
          AddDependencies(LVersion, LInfo);
          APackage.Versions.Add(LVersion);
        end;
        if SameText(AFirstVersion, LVersionName) then
          Break;
      end;
    finally
      LArray.Free;
    end;
  finally
    LInfo.Free;
  end;
end;

function TDNBitbucketPackageProvider.GetFileStream(const AAuthor, ARepository,
  AVersion, AFilePath: string; AFile: TStream): Boolean;
begin
  FClient.Accept := CMediaTypeRaw;
  try
//    Result := FClient.Get(Format(CBitbucketFileContent, [AAuthor, ARepository, AFilePath, AVersion]), AFile) = HTTPErrorOk;
    if not Result then
      CheckRateLimit();
  finally
    FClient.Accept := '';
  end;
end;

function TDNBitbucketPackageProvider.GetFileText(const AAuthor, ARepository,
  AVersion, AFilePath: string; out AText: string): Boolean;
begin
  FClient.Accept := CMediaTypeRaw;
  try
//    Result := FClient.GetText(Format(CBitbucketFileContent, [AAuthor, ARepository, AFilePath, AVersion]), AText) = HTTPErrorOk;
    if not Result then
      CheckRateLimit();
  finally
    FClient.Accept := '';
  end;
end;

function TDNBitbucketPackageProvider.GetInfoFile(const AAuthor, ARepository,
  AVersion: string; AInfo: TInfoFile): Boolean;
var
  LResponse: string;
begin
  FClient.Accept := CMediaTypeRaw;
  try
    Result := GetFileText(AAuthor, ARepository, AVersion, CInfoFile, LResponse)
      and AInfo.LoadFromString(LResponse);
    if not Result then
      CheckRateLimit();
  finally
    FClient.Accept := '';
  end;
end;

function TDNBitbucketPackageProvider.GetLicense(
  const APackage: TDNBitbucketPackage): string;
begin
  Result := 'No Licensefile has been provided.' + sLineBreak + 'Contact the Packageauthor to fix this issue by using the report-button.';
  if (APackage.LicenseFile <> '') then
  begin
    if GetFileText(APackage.Author, APackage.RepositoryName, APackage.DefaultBranch, APackage.LicenseFile, Result) then
    begin
      //if we do not detect a single Windows-Linebreak, we assume Posix-LineBreaks and convert
      if not ContainsStr(Result, sLineBreak) then
        Result := StringReplace(Result, #10, sLineBreak, [rfReplaceAll]);
    end
    else
    begin
      Result := 'An error occured while downloading the license information.' + sLineBreak + 'The file might be missing.';
    end;
  end;
end;

function TDNBitbucketPackageProvider.GetPushDateFile: string;
begin
  Result := TPath.Combine(GetDelphinusTempFolder(), CPushDates);
end;

function TDNBitbucketPackageProvider.GetReleaseText(const AAuthor,
  ARepository: string; out AReleases: string): Boolean;
begin
//  Result := FClient.GetText(Format(CBitbucketRepoReleases, [AAuthor, ARepository]), AReleases) = HTTPErrorOk;
  if not Result then
    CheckRateLimit();
end;

function TDNBitbucketPackageProvider.GetRepoList(out ARepos: TJSONArray): Boolean;
var
  LRoot: TJSONObject;
  LSearchResponse: string;
begin
  Result := FClient.GetText(CGitRepoSearch, LSearchResponse) = HTTPErrorOk;
  if Result then
  begin
    LRoot := TJSONObject.ParseJSONValue(LSearchResponse)as TJSONObject;
    try
      ARepos := LRoot.GetValue('items') as TJSONArray;
      ARepos.Owned := False;
    finally
      LRoot.Free;
    end;
  end;
end;

procedure TDNBitbucketPackageProvider.HandleDownloadProgress(AProgress,
  AMax: Int64);
begin
  FProgress.SetTaskProgress('Archive', AProgress, AMax);
end;

procedure TDNBitbucketPackageProvider.LoadPicture(APicture: TPicture; AAuthor, ARepository, AVersion, APictureFile: string);
var
  LPicStream: TMemoryStream;
  LPictureFile: string;
begin
  LPicStream := TMemoryStream.Create();
  try
    LPictureFile := StringReplace(APictureFile, '\', '/', [rfReplaceAll]);
    if GetFileStream(AAuthor, ARepository, AVersion, LPictureFile, LPicStream) then
    begin
      LPicStream.Position := 0;
      TGraphicLoader.TryLoadPictureFromStream(LPicStream, ExtractFileExt(LPictureFile), APicture);
    end;
  finally
    LPicStream.Free;
  end;
end;

procedure TDNBitbucketPackageProvider.LoadPushDates;
var
  LDates: TStringList;
  i: Integer;
begin
  FDateMutex.Acquire();
  FPushDates.Clear;

  if not TFile.Exists(GetPushDateFile()) then
    Exit;

  LDates := TStringList.Create();
  try
    LDates.LoadFromFile(GetPushDateFile());
    for i := 0 to LDates.Count - 1 do
      FPushDates.Add(LDates.Names[i], LDates.ValueFromIndex[i]);
  finally
    LDates.Free;
  end;
end;

function TDNBitbucketPackageProvider.Reload: Boolean;
var
  LRepo: TJSONObject;
  LRepos: TJSONArray;
  i: Integer;
begin
  Result := False;
  try
//    (FState as TDNBitbucketPackageProviderState).Reset();
    FProgress.SetTasks(['Reolading']);
    try
      LoadPushDates();
      FClient.BeginWork();
      try
        if GetRepoList(LRepos) then
        begin
          try
            Packages.Clear();
            FExistingIDs.Clear();
            for i := 0 to LRepos.Count - 1 do
            begin
              LRepo := LRepos.Items[i] as TJSONObject;
              FProgress.SetTaskProgress(LRepo.GetValue('name').Value, i, LRepos.Count);
              AddPackageFromJSon(LRepo);
            end;
            FProgress.Completed();
            Result := True;
          finally
            LRepos.Free;
          end;
        end;
      finally
        FClient.EndWork();
      end;
    finally
      SavePushDates();
    end;
  except
    on E: ERateLimitException do
//      (FState as TDNBitbucketPackageProviderState).SetError(E.Message)
  end;
end;

procedure TDNBitbucketPackageProvider.SavePushDates;
var
  LDates: TStringList;
  LKeys, LValues: TArray<string>;
  i: Integer;
begin
  LDates := TStringList.Create();
  try
    LKeys := FPushDates.Keys.ToArray();
    LValues := FPushDates.Values.ToArray();
    for i := 0 to FPushDates.Count - 1 do
      LDates.Add(LKeys[i] + '=' + LValues[i]);
    LDates.SaveToFile(GetPushDateFile());
  finally
    LDates.Free;
    FDateMutex.Release();
  end;
end;

end.
