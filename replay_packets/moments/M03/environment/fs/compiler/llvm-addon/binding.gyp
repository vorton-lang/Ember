{
  "targets": [
    {
      "target_name": "llvm_addon",
      "sources": ["llvm_addon.cpp"],
      "include_dirs": [
        "C:/Users/Yufeng Ying/scoop/apps/llvm/current/include"
      ],
      "conditions": [
        ["OS=='win'", {
          "library_dirs": [
            "C:/Users/Yufeng Ying/scoop/apps/llvm/current/lib"
          ],
          "libraries": [
            "LLVM-C.lib"
          ],
          "msvs_settings": {
            "VCCLCompilerTool": {
              "AdditionalOptions": ["/std:c++17"],
              "ExceptionHandling": 1
            }
          },
          "defines": [
            "_CRT_SECURE_NO_WARNINGS",
            "NOMINMAX"
          ]
        }]
      ]
    }
  ]
}
