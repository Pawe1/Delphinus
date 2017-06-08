unit DN.Package.Bitbucket;

interface

uses
  Classes,
  Types,
  DN.Package;

type
  TDNBitbucketPackage = class;

  TGetLicenseCallback = function(const APackage: TDNBitbucketPackage): string of object;

  TDNBitbucketPackage = class(TDNPackage)
  private
    FDefaultBranch: string;
    FRepositoryName: string;
    FLicenseFile: string;
    FOnGetLicense: TGetLicenseCallback;
    FLicenseLoaded: Boolean;
  protected
    function GetLicenseText: string; override;
  public
    property DefaultBranch: string read FDefaultBranch write FDefaultBranch;
    property RepositoryName: string read FRepositoryName write FRepositoryName;
    property LicenseFile: string read FLicenseFile write FLicenseFile;
    property OnGetLicense: TGetLicenseCallback read FOnGetLicense write FOnGetLicense;
  end;

implementation

{ TDNBitbucketPackage }

function TDNBitbucketPackage.GetLicenseText: string;
begin
  if (not FLicenseLoaded) and Assigned(FOnGetLicense) then
  begin
    LicenseText := FOnGetLicense(Self);
    FLicenseLoaded := True;
  end;
  Result := inherited;
end;

end.

