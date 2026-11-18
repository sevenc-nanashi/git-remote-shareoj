///|
pub struct Remote {
  api_host : @moonurl.Url
  id : @moonuuid.Uuid
}

///|
#derive(Debug)
pub suberror ParseRemoteError {
  InvalidUrl(@moonurl.Refused)
  InvalidRemote(@moonurl.Url)
  InvalidId(@moonuuid.Refused)
}

///|
/// remote URLを解析する
/// 仕様メモ：
/// - `shareoj://<host_and>/<path_to_api>/<id_with_hash>`
/// - `<host_and>/<path_to_api>`はAPIのホスト名とパスを含む
/// - とりあえずhttps固定（将来的に`?transport=http`みたいにしても良いかも）
/// - `<id_with_hash>`：もし`#`がついていればそれ以降をIDとして扱う。ついていなければそのままIDとして扱う
///   - 主な目的としては`custom_readable_name#uuid`みたいなURLを許容するため
pub fn Remote::parse_url(url : String) -> Remote raise ParseRemoteError {
  let url = @moonurl.Url::decode(url) catch {
    e => raise ParseRemoteError::InvalidUrl(e)
  }

  if url.scheme != Some("shareoj") {
    raise ParseRemoteError::InvalidRemote(url)
  }

  let segments = url.path.split("/").collect()
  let _ = segments.pop()
  let api_host = @moonurl.Url::{
    ..url,
    scheme: Some("https"),
    fragment: None,
    path: segments.join("/"),
  }
  match url.fragment {
    Some(fragment) => {
      let uuid = @moonuuid.parse(fragment) catch {
        e => raise ParseRemoteError::InvalidId(e)
      }

      Remote::{ api_host, id: uuid, }
    }
    None => {
      let path = url.path
      let last_segment = path.split("/").last()
      let maybe_id = last_segment.unwrap_or_default().to_owned()

      let uuid = @moonuuid.parse(maybe_id) catch {
        e => raise ParseRemoteError::InvalidId(e)
      }

      Remote::{ api_host, id: uuid, }
    }
  }
}

///|
test "Remote::parse_url: No friendly name" {
  let url = "shareoj://api.share-oj.net/83e3462b-3712-4ad6-b42f-eeac499470a8"
  let remote = try! Remote::parse_url(url)
  assert_eq(remote.api_host, @moonurl.Url::decode("https://api.share-oj.net"))
  assert_eq(remote.id, @moonuuid.parse("83e3462b-3712-4ad6-b42f-eeac499470a8"))
}

///|
test "Remote::parse_url: With friendly name" {
  let url = "shareoj://api.share-oj.net/custom_readable_name#83e3462b-3712-4ad6-b42f-eeac499470a8"
  let remote = try! Remote::parse_url(url)
  assert_eq(
    remote.api_host,
    @moonurl.Url::decode("https://api.share-oj.net"),
  )
  assert_eq(remote.id, @moonuuid.parse("83e3462b-3712-4ad6-b42f-eeac499470a8"))
}
