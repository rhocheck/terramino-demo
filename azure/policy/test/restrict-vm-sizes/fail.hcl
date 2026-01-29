mock "tfplan/v2" {
  module {
    source = "mock-fail.sentinel"
  }
}

test {
  rules = {
    main = false
  }
}
