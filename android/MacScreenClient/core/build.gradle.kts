plugins {
    kotlin("jvm")
}

// 纯 JVM 模块：协议编解码、坐标映射、语音转写逻辑、连接客户端。禁止依赖 android.*。
dependencies {
    implementation("org.json:json:20240303")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
    }
}
