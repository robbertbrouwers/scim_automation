from azure.core.credentials import TokenCredential
from azure.keyvault.secrets import SecretClient


def get_secrets(vault_url: str, names: list[str], credential: TokenCredential) -> dict[str, str]:
    client = SecretClient(vault_url=vault_url, credential=credential)
    return {name: client.get_secret(name).value for name in names}
