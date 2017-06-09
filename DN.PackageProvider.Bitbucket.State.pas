unit DN.PackageProvider.Bitbucket.State;

interface

uses
  DN.PackageProvider.State,
  DN.PackageProvider.State.Intf,
  DN.HttpClient.Intf;

type
  TDNBitbucketPackageProviderState = class(TDNPackageProviderState)
  private
    FClient: IDNHttpClient;
  protected
    function GetStatisticCount: Integer; override;
    function GetStatisticName(const AIndex: Integer): string; override;
    function GetStatisticValue(const AIndex: Integer): string; override;
  public
    constructor Create(const AClient: IDNHttpClient);
  end;

implementation

{ TDNBitbucketPackageProviderState }

constructor TDNBitbucketPackageProviderState.Create(const AClient: IDNHttpClient);
begin
  inherited Create;
  FClient := AClient;
end;

function TDNBitbucketPackageProviderState.GetStatisticCount: Integer;
begin
  Result := 3;
end;

function TDNBitbucketPackageProviderState.GetStatisticName(
  const AIndex: Integer): string;
begin
  case AIndex of
    0: Result := 'Ratelimit';
    1: Result := 'RateLimit-Remaining';
    2: Result := 'RateLimit-Reset';
  else
    Result := '';
  end;
end;

function TDNBitbucketPackageProviderState.GetStatisticValue(
  const AIndex: Integer): string;
begin
  case AIndex of
    0: Result := FClient.ResponseHeader['X-RateLimit-Limit'];
    1: Result := FClient.ResponseHeader['X-RateLimit-Remaining'];
    2: Result := FClient.ResponseHeader['X-RateLimit-Reset'];
  else
    Result := '';
  end;
end;

end.
