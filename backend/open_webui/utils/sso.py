import os, asyncio, hashlib, aiohttp, xmltodict, logging, re
from urllib.parse import quote_plus

log = logging.getLogger(__name__)

PRO_URL    = os.getenv("SSO_PRO_URL",    "http://bam.fsig.com.cn:8080/fsig-service/services?wsdl")
BACKUP_URL = os.getenv("SSO_BACKUP_URL", "http://192.168.1.186:8080/fsig-service/services?wsdl")
ESB_URL    = os.getenv("SSO_ESB_URL",    "http://esb.fsig.com.cn/home/system/com.eibus.web.soap.Gateway.wcp")
SYSTEM_FLAG      = os.getenv("SSO_SYSTEM_FLAG", "oa")
FROM_SYSTEM_FLAG = os.getenv("SSO_FROM_SYSTEM_FLAG", "oa")
PUB_KEY          = os.getenv("SSO_PUB_KEY", "F10AA5DBE73E110A")

HEADERS = {"Content-Type": "text/xml"}
TIMEOUT = aiohttp.ClientTimeout(total=5)


def _md5(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()

async def _post_xml(url: str, xml: str) -> str:
    async with aiohttp.ClientSession(timeout=TIMEOUT) as sess:
        async with sess.post(url, data=xml.encode("utf-8"), headers=HEADERS) as resp:
            resp.raise_for_status()
            return await resp.text()

async def _parse_xml(text: str):
    """Parse SOAP XML to dict, stripping namespace prefixes so that tags like
    ``soapenv:Envelope`` become simply ``Envelope``. This avoids brittle
    namespace-aware key access (the previous implementation caused KeyError
    when the parser returned tuple-based keys).

    We *intentionally* keep ``process_namespaces=False`` because we remove the
    prefixes up-front.  Any parsing failure will raise so that the caller can
    handle fallback logic.
    """
    # Remove XML namespace prefixes (``abc:Tag`` -> ``Tag``)
    try:
        text_no_ns = re.sub(r"(<\/?)([A-Za-z0-9_\-]+:)", r"\1", text)
        return xmltodict.parse(
            text_no_ns,
            process_namespaces=False,
            attr_prefix="",
            cdata_key="text",
            dict_constructor=dict,
        )
    except Exception:
        # Fall back to best-effort parse without stripping (may still succeed)
        return xmltodict.parse(
            text,
            process_namespaces=False,
            attr_prefix="",
            cdata_key="text",
            dict_constructor=dict,
        )

async def _valid_token_backup(token: str):
    soap = f"""
<soapenv:Envelope xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:iam=\"http://iam.fsig.com.cn/\">
 <soapenv:Header/>
 <soapenv:Body>
  <iam:validToken>
    <iam:tokenStr>{token}</iam:tokenStr>
    <iam:appIdFlag></iam:appIdFlag>
  </iam:validToken>
 </soapenv:Body>
</soapenv:Envelope>"""
    try:
        txt = await _post_xml(BACKUP_URL, soap)
        doc = await _parse_xml(txt)
        try:
            res = doc["Envelope"]["Body"]["validTokenResponse"]
        except Exception as ex:
            log.error(f"unexpected backup xml structure: {ex} | root_keys={list(doc.keys())}")
            return {"resultFlg": "false", "msgContent": "Invalid XML structure"}
        resultFlg = res.get("resultFlg", "false")
        if str(resultFlg).lower() == "true":
            userAcct = res.get("userAcct", "")
            userId   = res.get("userId",   "")
            if userAcct and len(userAcct) < 4:
                userAcct = f"bbm_{userAcct}"
            return {"resultFlg": "true", "userAcct": userAcct, "userId": userId}
        else:
            return {"resultFlg": "false", "msgCode": res.get("msgCode"), "msgContent": res.get("msgContent")}
    except Exception as e:
        log.error(f"backup url failed: {e}")
        return None

async def _valid_token_pro(token: str):
    soap = f"""
<soapenv:Envelope xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:iam=\"http://iam.fsig.com.cn/\">
 <soapenv:Header/>
 <soapenv:Body>
  <iam:validToken>
    <iam:tokenStr>{token}</iam:tokenStr>
    <iam:appIdFlag></iam:appIdFlag>
  </iam:validToken>
 </soapenv:Body>
</soapenv:Envelope>"""
    try:
        txt = await _post_xml(PRO_URL, soap)
        doc = await _parse_xml(txt)

        try:
            body = (
                doc["Envelope"]["Body"]["validTokenResponse"]["ValidTokenResultResponse"]["rtnIsValidToken"]
            )
            rtnMsg = body["rtnMessageInfo"]
        except Exception as ex:
            # Structure not as expected – log once and fall back
            log.error(f"unexpected xml structure: {ex} | root_keys={list(doc.keys())}")
            return await _valid_token_backup(token)

        resultFlg = rtnMsg["resultFlg"]
        if str(resultFlg).lower() == "true":
            userAcct = body["userAcct"]
            userId = body.get("userId", "")
            if userAcct and len(userAcct) < 4:
                userAcct = f"bbm_{userAcct}"
            return {"resultFlg": "true", "userAcct": userAcct, "userId": userId}
        else:
            msgCode = rtnMsg.get("msgCode", "")
            if str(msgCode).upper() in ["E401", "E402", "E900"]:
                return {"resultFlg": "false", "msgCode": msgCode, "msgContent": rtnMsg.get("msgContent")}
            # fallback
            return await _valid_token_backup(token)
    except Exception as e:
        log.error(f"pro url failed: {e}")
        return await _valid_token_backup(token)

async def valid_token(token: str):
    # ESB 方式需要签名，这里直接调用 pro/backup 实现，与 JS 里 validTokenproUrl 保持一致
    return await _valid_token_pro(token) 