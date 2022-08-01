### Welcome to my GitHub profile page 👋

My name is Nikolaos Dimopoulos. I am a sofware developer (primarily PHP) and am passionate about open-source!

---

#### :wrench: Work in progress
{{range recentContributions 10}}
- [{{.Repo.Name}}]({{.Repo.URL}}) - {{.Repo.Description}} ({{humanize .OccurredAt}})
{{- end}}

#### :pushpin: Latest releases I've contributed to
{{range recentReleases 10}}
- [{{.Name}}]({{.URL}}) ([{{.LastRelease.TagName}}]({{.LastRelease.URL}}), {{humanize .LastRelease.PublishedAt}}) - {{.Description}}
{{- end}}

#### 🔨 My recent Pull Requests
{{range recentPullRequests 10}}
- [{{.Title}}]({{.URL}}) on [{{.Repo.Name}}]({{.Repo.URL}}) ({{humanize .CreatedAt}})
{{- end}}


#### 📊 My stats

<img align="right" alt="niden's GitHub stats" src="https://github-readme-stats.vercel.app/api?username=niden&count_private=1&show_icons=true&" />

![Top Languages](https://github-readme-stats.vercel.app/api/top-langs/?username=niden)

#### 👯 Recent followers
{{range followers 5}}
- [{{.Login}}]({{.URL}})
{{- end}}
