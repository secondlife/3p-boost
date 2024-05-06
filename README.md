# 3p-boost

[Autobuild][]-packaged [boost][]

## Submodules

This repository vendors boost using submodules. Be sure to pull them when cloning or updating this repository.

Fresh clone:
```
git clone --recurse-submodules git@github.com:secondlife/3p-boost.git
```

Existing checkout:
```
git submodule update --init --recursive
```

Since boost has a _lot_ of submodules you may want to enable parallel submodule jobs:

```
git config --global submodule.fetchJobs $(nproc)
```

[Autobuild]: https://wiki.secondlife.com/wiki/Autobuild 
[boost]: https://www.boost.org/ 