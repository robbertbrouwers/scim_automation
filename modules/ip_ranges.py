import re

import requests

_CIDR_RE = re.compile(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$")
_CONFIRM_URL = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519"
_JSON_URL_RE = re.compile(
    r"https://download\.microsoft\.com/download/[^\s\"]+ServiceTags_Public_\d+\.json"
)


def get_entra_provisioning_ips() -> list[str]:
    """
    Returns current AzureActiveDirectory IPv4 CIDR ranges from Microsoft's
    published Service Tags JSON. IPv6 prefixes are silently dropped since
    Snowflake TYPE=IPV4 network rules do not accept them.
    """
    page = requests.get(_CONFIRM_URL, timeout=30)
    page.raise_for_status()

    match = _JSON_URL_RE.search(page.text)
    if not match:
        raise ValueError("Could not locate Service Tags download URL on the confirmation page")

    data = requests.get(match.group(0), timeout=120).json()

    for entry in data["values"]:
        if entry["name"] == "AzureActiveDirectory":
            raw: list[str] = entry["properties"]["addressPrefixes"]
            ipv4 = [ip for ip in raw if _CIDR_RE.match(ip)]
            if not ipv4:
                raise ValueError("No valid IPv4 CIDR ranges found for AzureActiveDirectory")
            return ipv4

    raise ValueError("AzureActiveDirectory service tag not found in Microsoft's Service Tags JSON")
