# 签名与 iCloud 配置

AY Translate 1.0.0 的主应用为 `com.atlanyuey.translate`，分享扩展为 `com.atlanyuey.translate.ShareExtension`。

1. 在 Apple Developer 注册两个显式 App ID。
2. 注册 `group.com.atlanyuey.translate`，将主应用和分享扩展均关联到该 App Group。
3. 主应用开启 iCloud 的键值存储能力。当前实现是 `NSUbiquitousKeyValueStore`，不使用 CloudKit，因此不需要 CloudKit 记录类型或数据库部署。
4. 为两个目标生成包含相应权限的描述文件；共享钥匙串组为团队前缀加 `com.atlanyuey.translate`。主应用的 KVS 标识为团队前缀加 `com.atlanyuey.translate`。
5. 在 Xcode 或自签工具中保留 entitlements 与描述文件允许的对应值。不能把工程中的 `$(TeamIdentifierPrefix)` 原样写进最终签名；构建/签名过程应解析为真实团队前缀。
6. 使用同一 iCloud 账号、兼容的签名身份在各设备安装，在应用设置中开启同步。首次同步及后续到达时间由 iCloud 调度。

购买的普通企业证书或重签描述文件可能不支持 iCloud，必须向签名提供方确认 App ID 和 KVS 权限可用。不能仅因装得上 IPA 就判定 iCloud 已开通。本仓库没有访问你的 Apple Developer 账号，也没有注册这些标识或验证你的 Feather 描述文件；提供的是已配置的新应用源码与未签名安装包。

新 Bundle ID 与旧测试版隔离。先使用旧版的本机配置复制/导入功能迁移设置及密钥，再启用新版 iCloud。API Key、图片、历史和调用许可不进入 iCloud KVS。
