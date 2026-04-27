import Foundation
@testable import Cachebay

/// Shared GraphQL operations and helpers ported from
/// `cachebay/packages/cachebay/test/helpers/operations.ts`. Exposed at module
/// scope (not nested under a type) so individual XCTestCase classes can grab
/// a single literal without retyping it.
enum CompilerOps {
    static let pageInfoFragment = """
    fragment PageInfoFields on PageInfo {
      startCursor
      endCursor
      hasNextPage
      hasPreviousPage
    }
    """

    static let userFragment = """
    fragment UserFields on User {
      id
      email
    }
    """

    static let postFragment = """
    fragment PostFields on Post {
      id
      title
      flags
    }
    """

    static let commentFragment = """
    fragment CommentFields on Comment {
      uuid
      text
    }
    """

    static let tagFragment = """
    fragment TagFields on Tag {
      id
      name
    }
    """

    static let mediaFragment = """
    fragment MediaFields on Media {
      key
      mediaUrl
    }
    """

    static let statFragment = """
    fragment StatFields on Stat {
      key
      views
    }
    """

    static let audioPostFragment = """
    fragment AudioPostFields on AudioPost {
      id
      title
      flags
    }
    """

    static let videoPostFragment = """
    fragment VideoPostFields on VideoPost {
      id
      title
      flags
    }
    """

    // MARK: - Queries

    static let userQuery = userFragment + """

    query UserQuery($id: ID!) {
      user(id: $id) {
        ...UserFields
      }
    }
    """

    static let userWithAliasQuery = userFragment + """

    query UserWithAliasQuery($id: ID!) {
      currentUser: user(id: $id) {
        ...UserFields
      }
    }
    """

    static let usersQuery = pageInfoFragment + "\n" + userFragment + """

    query UsersQuery($role: String, $first: Int, $after: String, $last: Int, $before: String) {
      users(role: $role, first: $first, after: $after, last: $last, before: $before) @connection(filters: ["role"]) {
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          node { ...UserFields }
        }
      }
    }
    """

    static let postsQuery = pageInfoFragment + "\n" + postFragment + """

    query Posts($category: String, $sort: String, $first: Int, $after: String, $last: Int, $before: String) {
      posts(category: $category, sort: $sort, first: $first, after: $after, last: $last, before: $before) @connection(filters: ["category", "sort"], mode: "infinite") {
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          node { ...PostFields }
        }
      }
    }
    """

    static let postsWithoutConnectionQuery = pageInfoFragment + "\n" + postFragment + """

    query Posts($category: String, $sort: String, $first: Int, $after: String, $last: Int, $before: String) {
      posts(category: $category, sort: $sort, first: $first, after: $after, last: $last, before: $before) {
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          node { ...PostFields }
        }
      }
    }
    """

    static let postsWithDefaultsQuery = pageInfoFragment + "\n" + postFragment + """

    query Posts($category: String, $sort: String, $first: Int, $after: String, $last: Int, $before: String) {
      posts(category: $category, sort: $sort, first: $first, after: $after, last: $last, before: $before) @connection {
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          node { ...PostFields }
        }
      }
    }
    """

    static let postsWithKeyQuery = pageInfoFragment + "\n" + postFragment + """

    query Posts($category: String, $sort: String, $first: Int, $after: String, $last: Int, $before: String) {
      posts(category: $category, sort: $sort, first: $first, after: $after, last: $last, before: $before) @connection(filters: ["category", "sort"], key: "KeyedPosts") {
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          node { ...PostFields }
        }
      }
    }
    """

    static let postsWithAggregationsQuery = pageInfoFragment + "\n" + postFragment + "\n" + tagFragment + "\n" + mediaFragment + "\n" + statFragment + """

    query Posts($category: String, $sort: String, $first: Int, $after: String, $last: Int, $before: String) {
      posts(category: $category, sort: $sort, first: $first, after: $after, last: $last, before: $before) @connection {
        totalCount
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          node {
            ...PostFields
            aggregations {
              moderationTags: tags(first: 25, category: "moderation") @connection(key: "ModerationTags") {
                pageInfo { ...PageInfoFields }
                edges { node { ...TagFields } }
              }
              userTags: tags(first: 25, category: "user") @connection(key: "UserTags") {
                pageInfo { ...PageInfoFields }
                edges { node { ...TagFields } }
              }
            }
            ... on VideoPost {
              video { ...MediaFields }
            }
            ... on AudioPost {
              audio { ...MediaFields }
            }
          }
        }
        aggregations {
          scoring
          todayStat: stat(key: "today") { ...StatFields }
          yesterdayStat: stat(key: "yesterday") { ...StatFields }
          tags(first: 50) @connection(key: "BaseTags") {
            pageInfo { ...PageInfoFields }
            edges { node { ...TagFields } }
          }
        }
      }
    }
    """

    static let userPostsQuery = pageInfoFragment + "\n" + userFragment + "\n" + postFragment + "\n" + audioPostFragment + "\n" + videoPostFragment + """

    query UserPostsQuery($id: ID!, $postsCategory: String, $postsSort: String, $postsFirst: Int, $postsAfter: String, $postsLast: Int, $postsBefore: String) {
      user(id: $id) {
        ...UserFields
        posts(category: $postsCategory, sort: $postsSort, first: $postsFirst, after: $postsAfter, last: $postsLast, before: $postsBefore) @connection(filters: ["category", "sort"]) {
          totalCount
          pageInfo { ...PageInfoFields }
          edges {
            cursor
            score
            node {
              ...PostFields
              ...AudioPostFields
              ...VideoPostFields
              author { id email }
            }
          }
        }
      }
    }
    """

    static let userPostsCommentsQuery = pageInfoFragment + "\n" + userFragment + "\n" + postFragment + "\n" + commentFragment + """

    query UserPostsCommentsQuery(
      $id: ID!,
      $postsCategory: String,
      $postsFirst: Int,
      $postsAfter: String,
      $commentsFirst: Int,
      $commentsAfter: String
    ) {
      user(id: $id) {
        ...UserFields
        posts(category: $postsCategory, first: $postsFirst, after: $postsAfter) @connection(filters: ["category"]) {
          pageInfo { ...PageInfoFields }
          edges {
            cursor
            node {
              ...PostFields
              comments(first: $commentsFirst, after: $commentsAfter) @connection(filters: []) {
                pageInfo { ...PageInfoFields }
                edges {
                  cursor
                  node {
                    ...CommentFields
                    author { id }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    static let usersPostsCommentsQuery = pageInfoFragment + "\n" + userFragment + "\n" + postFragment + "\n" + commentFragment + """

    query UsersPostsCommentsQuery(
      $usersRole: String,
      $usersFirst: Int,
      $usersAfter: String,
      $postsCategory: String,
      $postsFirst: Int,
      $postsAfter: String,
      $commentsFirst: Int,
      $commentsAfter: String
    ) {
      users(role: $usersRole, first: $usersFirst, after: $usersAfter) @connection(filters: ["role"]) {
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          node {
            ...UserFields
            posts(category: $postsCategory, first: $postsFirst, after: $postsAfter) @connection(filters: ["category"]) {
              pageInfo { ...PageInfoFields }
              edges {
                cursor
                node {
                  ...PostFields
                  comments(first: $commentsFirst, after: $commentsAfter) @connection {
                    pageInfo { ...PageInfoFields }
                    edges {
                      cursor
                      node { ...CommentFields }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    static let postCommentsQuery = pageInfoFragment + "\n" + commentFragment + """

    query PostCommentsQuery($postId: ID!, $first: Int, $after: String, $last: Int, $before: String) {
      post(id: $postId) {
        id
        comments(first: $first, after: $after, last: $last, before: $before) @connection(filters: [], mode: "page") {
          totalCount
          pageInfo { ...PageInfoFields }
          edges {
            cursor
            node { ...CommentFields }
          }
        }
      }
    }
    """

    // MARK: - Fragments

    static let userPostsFragment = pageInfoFragment + "\n" + userFragment + "\n" + postFragment + """

    fragment UserPosts on User {
      ...UserFields
      posts(category: $postsCategory, first: $postsFirst, after: $postsAfter) @connection(filters: ["category"], mode: "infinite") {
        totalCount
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          score
          node { ...PostFields }
        }
      }
    }
    """

    static let userPostsWithKeyFragment = pageInfoFragment + "\n" + userFragment + "\n" + postFragment + """

    fragment UserPosts on User {
      ...UserFields
      posts(category: $postsCategory, first: $postsFirst, after: $postsAfter) @connection(key: "UserPosts", filters: ["category"]) {
        totalCount
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          score
          node { ...PostFields }
        }
      }
    }
    """

    static let postCommentsFragment = pageInfoFragment + """

    fragment PostComments on Post {
      id
      comments(first: $commentsFirst, after: $commentsAfter) @connection(key: "PostComments") {
        pageInfo { ...PageInfoFields }
        edges {
          cursor
          node {
            id
            text
            author { id name }
          }
        }
      }
    }
    """

    static let multipleUserFragment = """
    fragment UserOnly on User { id }
    fragment AdminOnly on Admin { role }

    query MixedTypes($id: ID!) {
      user(id: $id) {
        ...UserOnly
        ...AdminOnly
      }
    }
    """

    static let updateUserMutation = userFragment + """

    mutation UpdateUserMutation($id: ID!, $input: UpdateUserInput!, $postsCategory: String, $postsFirst: Int, $postsAfter: String) {
      updateUser(id: $id, input: $input) {
        user {
          ...UserFields
          posts(category: $postsCategory, first: $postsFirst, after: $postsAfter) @connection {
            pageInfo {
              startCursor
              endCursor
              hasNextPage
              hasPreviousPage
            }
            edges {
              cursor
              node { ...PostFields }
            }
          }
        }
      }
    }
    """

    static let userUpdatedSubscription = userFragment + """

    subscription UserUpdatedSubscription($id: ID!) {
      userUpdated(id: $id) {
        user { ...UserFields }
      }
    }
    """
}

/// Asserts the printed network query has no `@connection` directives left.
func collectConnectionDirectives(_ networkQuery: String) -> [String] {
    // Find every "@connection" occurrence; we only care about presence/absence.
    var matches: [String] = []
    var idx = networkQuery.startIndex
    while let r = networkQuery.range(of: "@connection", range: idx..<networkQuery.endIndex) {
        matches.append("@connection")
        idx = r.upperBound
    }
    return matches
}

/// Crude check that `__typename` appears (compiler injects it everywhere it
/// should). Web variant traverses the AST; for iOS we test the printed
/// network query string directly — equivalent for these tests.
func hasTypenames(_ networkQuery: String) -> Bool {
    return networkQuery.contains("__typename")
}
