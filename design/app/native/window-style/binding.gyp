{
  "targets": [
    {
      "target_name": "window_style",
      "conditions": [
        ["OS=='mac'", {
          "sources": ["window_style.mm"],
          "link_settings": { "libraries": ["-framework AppKit"] },
          "xcode_settings": {
            "MACOSX_DEPLOYMENT_TARGET": "13.0",
            "CLANG_ENABLE_OBJC_ARC": "YES"
          }
        }]
      ]
    }
  ]
}
