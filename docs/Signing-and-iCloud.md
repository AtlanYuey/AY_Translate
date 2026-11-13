# 签名与 iCloud 配置

AY Translate 由主程序 `com.atlanyuey.translate` 和分享扩展 `com.atlanyuey.translate.ShareExtension` 组成。截屏后在当前应用上方显示译图的就是分享扩展，所以两者都要签名。

## 在 Apple Developer 网站上

1. **Identifiers → App Groups**：注册 `group.com.atlanyuey.translate`。
2. **Identifiers → App IDs**：注册两个显式 App ID（上面两个 Bundle ID），两个都勾选 **App Groups**，并选中上一步的组。
3. 主程序的 App ID 再勾选 **iCloud**（只用键值存储，不需要 CloudKit 容器或数据库部署）。
4. **Profiles**：为两个 App ID 各生成一个描述文件，选同一张证书和要安装的设备。

**重要**：描述文件生成那一刻会把 App ID 的能力“拍下来”。之后在 App ID 上新开了能力（例如 App Groups），必须重新生成描述文件，旧的不会自动更新。可以用下面的命令确认描述文件里有没有这个组：

```bash
security cms -D -i AY_Translate.mobileprovision | grep -A2 application-groups
```

## 签名时的权限

| | 主程序 | 分享扩展 |
| --- | --- | --- |
| `application-identifier` | `<团队ID>.com.atlanyuey.translate` | `<团队ID>.com.atlanyuey.translate.ShareExtension` |
| `com.apple.security.application-groups` | `group.com.atlanyuey.translate` | `group.com.atlanyuey.translate` |
| `keychain-access-groups` | `<团队ID>.com.atlanyuey.translate` | `<团队ID>.com.atlanyuey.translate` |
| `com.apple.developer.ubiquity-kvstore-identifier` | `<团队ID>.com.atlanyuey.translate` | — |

工程里的 `$(TeamIdentifierPrefix)` 等变量必须在签名时换成真实团队 ID，不能原样写进最终签名。每个部分要嵌入自己的描述文件（`embedded.mobileprovision`）。Xcode 和 `fastlane resign` 都支持按 Bundle ID 分别指定描述文件；只能给整个 IPA 指定一个描述文件的工具，做不到这一点。

## 没有这些能力时

- **没有 App Group**（例如通配符描述文件）：仍可使用。设置改由共享钥匙串在主程序和扩展之间中转，略慢；两边连钥匙串组都没有时，用“设置 → 配置同步 → 复制配置与 API 密钥”手动导入。
- **没有 iCloud**：同步开关会提示描述文件不支持，其他功能不受影响。

## iCloud 同步

在“设置 → 配置同步”开启。同步语言、显示和 AI 服务配置；勾选“同时保存 API 密钥”后，密钥和已给出的云端许可也会同步，关闭时会从 iCloud 删除。截图、历史永远不同步。各设备需登录同一个 iCloud 账号，并安装同一团队签名的版本；到达时间由 iCloud 调度。
